from app.domain.services.falcon_service import _parse, plain_arabic


def test_arabic_answers_never_show_field_names():
    text = plain_arabic('راجع QA SKU 2903ea: qty_sold 2 مقابل total_profit 0 وقائمة reorder فارغة، some_field هنا')
    assert 'qty_sold' not in text and 'total_profit' not in text and 'reorder' not in text
    assert 'some_field' not in text
    assert 'QA SKU 2903ea' in text  # product names stay as they are
    assert 'الكمية المباعة 2' in text


def test_english_answers_keep_english_words():
    assert plain_arabic('Check qty_sold', 'en') == 'Check qty sold'


def test_report_is_short_and_not_repeated():
    parsed = _parse('{"attention":["a","b","c","d"],"recommendations":["a","c","d","e"]}')
    assert parsed['attention'] == ['a', 'b', 'c']
    assert parsed['recommendations'] == ['d', 'e']
