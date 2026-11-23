"""
Phone number validation, normalization and masking.

Uses the trusted `phonenumbers` (libphonenumber) library — never hand-rolled
regex — to validate real-world numbers, convert them to E.164, resolve the
country / calling code / line type and (where the library supports it) the
carrier. Numbers are stored as E.164 and masked everywhere they are exposed
back to clients so full numbers never leak through the API.

This module deliberately avoids the word "verified": a phone that passes
libphonenumber validation is *validated* (well-formed, real numbering plan),
not ownership-verified (which would require an OTP round trip).
"""

from dataclasses import dataclass
from typing import Optional

import phonenumbers
from phonenumbers import PhoneNumberType
from phonenumbers import carrier as _carrier
from phonenumbers.phonenumberutil import NumberParseException

DEFAULT_REGION = "SA"

_PHONE_TYPE_LABELS = {
    PhoneNumberType.MOBILE: "mobile",
    PhoneNumberType.FIXED_LINE: "fixed_line",
    PhoneNumberType.FIXED_LINE_OR_MOBILE: "fixed_line_or_mobile",
    PhoneNumberType.TOLL_FREE: "toll_free",
    PhoneNumberType.PREMIUM_RATE: "premium_rate",
    PhoneNumberType.SHARED_COST: "shared_cost",
    PhoneNumberType.VOIP: "voip",
    PhoneNumberType.PERSONAL_NUMBER: "personal_number",
    PhoneNumberType.PAGER: "pager",
    PhoneNumberType.UAN: "uan",
    PhoneNumberType.VOICEMAIL: "voicemail",
    PhoneNumberType.UNKNOWN: "unknown",
}


@dataclass(frozen=True)
class PhoneInfo:
    """Normalized, validated phone attributes safe to persist."""

    e164: str
    country: str  # ISO 3166-1 alpha-2 (from the number itself)
    country_code: str  # international calling code, e.g. "967"
    number_type: str  # "mobile" | "fixed_line" | ...
    carrier: Optional[str]  # operator when libphonenumber knows it, else None


def _parse(raw: str, region: Optional[str]) -> Optional["phonenumbers.PhoneNumber"]:
    try:
        if region:
            return phonenumbers.parse(raw, region=region)
        return phonenumbers.parse(raw, None)
    except NumberParseException:
        return None


def normalize_phone(
    raw: str, expected_country: Optional[str] = None
) -> PhoneInfo:
    """Validate and normalize a raw phone number into E.164 + metadata.

    Raises ``ValueError`` (Arabic message) when the number is malformed, not a
    real number, or does not match the country the user selected.
    """
    value = (raw or "").strip()
    if not value:
        raise ValueError("رقم الهاتف مطلوب")

    region = expected_country.strip().upper() if expected_country else None
    if region and region not in phonenumbers.SUPPORTED_REGIONS:
        raise ValueError("الدولة المحددة غير صالحة")

    number = _parse(value, region)
    if number is None:
        number = _parse(value, None)

    if number is None or not phonenumbers.is_valid_number(number):
        raise ValueError("رقم الهاتف غير صالح")

    if region:
        actual = phonenumbers.region_code_for_number(number)
        if actual and actual != region:
            raise ValueError("رقم الهاتف لا يطابق الدولة المختارة")

    e164 = phonenumbers.format_number(number, phonenumbers.PhoneNumberFormat.E164)
    country = phonenumbers.region_code_for_number(number) or region or DEFAULT_REGION
    number_type = _PHONE_TYPE_LABELS.get(
        phonenumbers.number_type(number), "unknown"
    )
    carrier = None
    try:
        carrier = _carrier.name_for_number(number, "en")
    except Exception:  # noqa: BLE001 — carrier metadata is best-effort only
        carrier = None

    return PhoneInfo(
        e164=e164,
        country=country,
        country_code=str(number.country_code),
        number_type=number_type,
        carrier=carrier,
    )


def is_valid_phone(phone: Optional[str], region: Optional[str] = None) -> bool:
    """True when a stored/entered phone is a well-formed real number.

    Used by the free-subscription gate: existing accounts that already hold a
    valid phone keep working, while malformed values are treated as missing.
    """
    value = (phone or "").strip()
    if not value:
        return False
    number = _parse(value, None) or _parse(value, region)
    return number is not None and phonenumbers.is_valid_number(number)


def mask_phone(phone: Optional[str]) -> Optional[str]:
    """Mask a phone so only the calling code + last 4 digits are visible.

    Never returns a full number. Non-parseable input is coarsely masked too.
    """
    if not phone:
        return None
    value = phone.strip()
    number = _parse(value, None) or _parse(value, DEFAULT_REGION)
    if number is not None and phonenumbers.is_valid_number(number):
        country_code = str(number.country_code)
        national = str(number.national_number)
        if len(national) <= 4:
            return f"+{country_code} {national}"
        return f"+{country_code} {'*' * (len(national) - 4)}{national[-4:]}"
    digits = "".join(ch for ch in value if ch.isdigit())
    if len(digits) <= 4:
        return f"****{digits}"
    return f"****{digits[-4:]}"
