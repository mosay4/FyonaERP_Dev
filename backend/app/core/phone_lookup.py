"""Indexed lookup keys; tolerate stored legacy formats, never guess a user."""
import unicodedata
import phonenumbers


def ascii_digits(raw):
    return ''.join(str(unicodedata.decimal(ch)) for ch in (raw or '') if ch.isdecimal())


def phone_lookup_keys(raw, region=None):
    text = (raw or '').strip()
    if not text or '*' in text or any(ch.isalpha() for ch in text):
        return None, None
    digits = ascii_digits(text)
    if len(digits) < 7 or len(digits) > 18:
        return None, None
    international = text.startswith('+') or digits.startswith('00') or (len(digits) > 10 and not region)
    full = digits[2:] if digits.startswith('00') else digits
    candidate = '+' + full if international else text
    try:
        number = phonenumbers.parse(candidate, region if not international else None)
        if phonenumbers.is_possible_number(number):
            full = ascii_digits(phonenumbers.format_number(number, phonenumbers.PhoneNumberFormat.E164))
            return full, str(number.national_number)
    except phonenumbers.NumberParseException:
        pass
    return full, full.lstrip('0')
