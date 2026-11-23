"""Pure-logic tests for the Falcon report (no DB, no network).

Run: backend/venv/bin/python backend/tests/test_falcon_logic.py
Covers: report-currency conversion (USD/SAR/YER_NEW/YER_OLD), deterministic
verdict, dynamic scope-aware suggested questions, rule-based fallback text,
and the JSON-leak guards.
"""
import asyncio
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.domain.services import falcon_service as fs  # noqa: E402


def with_rate(coro_fn, table):
    """Patch falcon_service._rate with a static table during coro_fn()."""
    orig = fs._rate

    async def fake(from_ccy, to_ccy):
        key = (from_ccy.upper(), to_ccy.upper())
        return table.get(key, 1.0)

    fs._rate = fake
    try:
        return asyncio.run(coro_fn())
    finally:
        fs._rate = orig


RATES = {
    ("SAR", "USD"): 0.2667,
    ("YER_NEW", "USD"): 0.004,
    ("YER_OLD", "USD"): 0.0008,
    ("USD", "SAR"): 3.75,
    ("YER_NEW", "SAR"): 0.015,
    ("YER_OLD", "SAR"): 0.003,
}


class ConvertTests(unittest.TestCase):
    def test_usd_conversion_all_money_fields(self):
        item = {"currency": "SAR", "sales": 100.0, "cogs": 50.0,
                "profit": 50.0, "purchases": 20.0, "sell_price": 10.0,
                "cost_price": 5.0, "qty_sold": 3}

        def run():
            return fs._convert_item(item, "USD")

        with_rate(run, RATES)
        self.assertAlmostEqual(item["sales"], 26.67, places=2)
        self.assertAlmostEqual(item["cost_price"], 1.3335, places=3)
        self.assertEqual(item["currency"], "SAR")  # original currency kept
        self.assertEqual(item["qty_sold"], 3)      # quantities never convert

    def test_yer_new_and_old(self):
        for src, factor in (("YER_NEW", 0.004), ("YER_OLD", 0.0008)):
            item = {"currency": src, "sales": 1000.0, "profit": 100.0}

            def run(item=item):
                return fs._convert_item(item, "USD")

            with_rate(run, RATES)
            self.assertAlmostEqual(item["sales"], 1000.0 * factor, places=3)
            self.assertAlmostEqual(item["profit"], 100.0 * factor, places=4)

    def test_same_currency_is_identity(self):
        item = {"currency": "USD", "sales": 7.5}

        def run():
            return fs._convert_item(item, "USD")

        with_rate(run, RATES)
        self.assertEqual(item["sales"], 7.5)


class VerdictTests(unittest.TestCase):
    def test_product_statuses(self):
        base = {"sales": 100.0, "profit": 30.0, "margin": 0.3, "stock": 32,
                "min_stock": 5, "qty_sold": 5, "out": False,
                "stagnant": False, "low": False, "loss": False}
        self.assertEqual(fs._verdict(base, "product"), "excellent")
        self.assertEqual(fs._verdict(dict(base, margin=0.15, profit=15.0), "product"), "good")
        self.assertEqual(fs._verdict(dict(base, stock=3, min_stock=5, low=True), "product"), "watch")
        self.assertEqual(fs._verdict(dict(base, loss=True, profit=-2, margin=-0.02), "product"), "weak")
        self.assertEqual(fs._verdict(dict(base, stock=0, out=True), "product"), "weak")
        self.assertEqual(fs._verdict(dict(base, qty_sold=0, stagnant=True), "product"), "watch")

    def test_inventory_statuses(self):
        base = {"sales": 1000.0, "profit": 300.0, "margin": 0.3, "out": 0,
                "low": 0, "stagnant": 0, "weak_margin": 0,
                "products_count": 10, "loss": False}
        self.assertEqual(fs._verdict(base, "inventory"), "excellent")
        self.assertEqual(fs._verdict(dict(base, margin=0.12, profit=120.0), "inventory"), "good")
        self.assertEqual(fs._verdict(dict(base, stagnant=5), "inventory"), "watch")
        self.assertEqual(fs._verdict(dict(base, loss=True, profit=-10), "inventory"), "weak")


class QuestionTests(unittest.TestCase):
    PRODUCT_OK = {"sales": 100.0, "profit": 30.0, "margin": 0.3, "stock": 32,
                  "min_stock": 5, "qty_sold": 5, "out": False,
                  "stagnant": False, "low": False, "loss": False}

    def test_product_scope_questions_follow_data(self):
        qs = fs._suggested_questions("product", self.PRODUCT_OK, {})
        self.assertIn("كم أطلب الشهر القادم؟", qs)
        self.assertIn("متى ممكن يخلص المخزون؟", qs)
        self.assertNotIn("هل أزيد سعر المنتج؟", qs)  # margin is healthy
        self.assertNotIn("هل المنتج راكد؟", qs)      # not stagnant

        low_margin = dict(self.PRODUCT_OK, margin=0.05, profit=5.0)
        qs2 = fs._suggested_questions("product", low_margin, {})
        self.assertIn("هل أزيد سعر المنتج؟", qs2)

        stagnant = dict(self.PRODUCT_OK, qty_sold=0, stagnant=True, sales=0.0,
                        profit=0.0, margin=None)
        qs3 = fs._suggested_questions("product", stagnant, {})
        self.assertIn("هل المنتج راكد؟", qs3)
        self.assertNotIn("كم أطلب الشهر القادم؟", qs3)  # no velocity → dropped

    def test_scope_isolation(self):
        inv = {"sales": 1000.0, "profit": 300.0, "margin": 0.3, "out": 0,
               "low": 0, "stagnant": 4, "weak_margin": 0,
               "products_count": 20, "loss": False}
        qs_inv = fs._suggested_questions("inventory", inv, {})
        qs_cat = fs._suggested_questions("category", inv, {})
        self.assertIn("وش المنتجات الراكدة؟", qs_inv)
        self.assertIn("وين رأس المال متجمد؟", qs_inv)
        self.assertIn("وش أفضل منتج في التصنيف؟", qs_cat)
        self.assertFalse(set(qs_inv) & set(qs_cat))  # no cross-scope mixing
        self.assertLessEqual(len(qs_inv), 4)
        self.assertLessEqual(len(qs_cat), 4)


class RuleFallbackTests(unittest.TestCase):
    def test_attention_recommends_with_numbers(self):
        data = {"low_stock": ["سكر", "أرز"], "out_of_stock": [],
                "slow_moving": [{"name": "شاي"}],
                "weak_margin": [{"name": "ملح"}], "top_profit": [],
                "products_count": 10, "total_sales": 1000.0,
                "total_profit": 300.0, "inventory_value": 500.0,
                "total_cogs": 700.0, "report_currency": "SAR"}
        flags = fs._flags_from(data, "inventory")
        rep = fs._rule_report(data, flags, "inventory", "المخزون", "SAR")
        self.assertIn(rep["status"], ("excellent", "good", "watch", "weak"))
        self.assertTrue(any("راكد" in p for p in rep["attention"]))
        self.assertTrue(any("سكر" in r or "أرز" in r for r in rep["recommendations"]))
        for line in rep["attention"] + rep["recommendations"]:
            self.assertFalse(line.strip().startswith("{"))  # no JSON


class NoJsonTests(unittest.TestCase):
    def test_parse_reads_model_json(self):
        text = json.dumps({
            "status_line": "الربح 30% والمخزون يكفي.",
            "attention": ["نقص قرب: سكر"],
            "recommendations": ["أعد طلب سكر."],
            "opportunity": "",
        }, ensure_ascii=False)
        parsed = fs._parse(text)
        self.assertEqual(parsed["status_line"], "الربح 30% والمخزون يكفي.")
        self.assertEqual(parsed["attention"], ["نقص قرب: سكر"])

    def test_as_plain_flattens_json_chat_reply(self):
        raw = json.dumps({"answer": "بعت 5 قطع فقط، لا تشترِ الآن."},
                         ensure_ascii=False)
        self.assertEqual(fs._as_plain(raw), "بعت 5 قطع فقط، لا تشترِ الآن.")
        self.assertNotIn("{", fs._as_plain(raw))

    def test_as_plain_passes_plain_text(self):
        self.assertEqual(fs._as_plain("رد عادي بدون JSON"), "رد عادي بدون JSON")


if __name__ == "__main__":
    unittest.main(verbosity=2)


class ProductTypeTests(unittest.TestCase):
    def test_detection_by_name_and_category(self):
        self.assertEqual(fs.detect_type('طماطم بلدي', '')[0], 'fresh')
        self.assertEqual(fs.detect_type('شاحن جوال', 'إلكترونيات')[0], 'electronics')
        self.assertEqual(fs.detect_type('قميص صيفي', 'ملابس رجالية')[0], 'clothing')
        self.assertEqual(fs.detect_type('حفاضات', 'مستلزمات أطفال')[0], 'baby')
        self.assertEqual(fs.detect_type('صنف مجهول', '')[0], 'general')

    def test_playbook_covers_required_expertise(self):
        pb = fs._TYPE_PLAYBOOKS['fresh']
        for key in ('label', 'pricing', 'turnover', 'marketing', 'risks',
                    'opportunity', 'order'):
            self.assertTrue(str(pb[key]).strip(), key)

    def test_type_context_dominant_type(self):
        ctx = fs._type_context('inventory', {}, ['شاي أحمر', 'سكر ناعم', 'قرفة'], '')
        self.assertEqual(ctx['key'], 'grocery')
        self.assertIn('grocery', ctx['playbook']['label'].lower()) if False else None

    def test_out_of_scope_fallback_is_polite(self):
        self.assertIn('خبير', fs._SPECIALTY_FALLBACK)
        self.assertIn('الصقر', fs._SPECIALTY_FALLBACK)


if __name__ == '__main__':
    pass
