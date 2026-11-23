"""Phone validation/masking unit tests (libphonenumber-backed, no DB)."""

import pytest

from app.core.phone_validation import (
    normalize_phone,
    is_valid_phone,
    mask_phone,
)


class TestNormalizePhone:
    def test_international_number_to_e164(self):
        info = normalize_phone("+967 777 304 569")
        assert info.e164 == "+967777304569"
        assert info.country == "YE"
        assert info.country_code == "967"
        assert info.number_type == "mobile"

    def test_national_number_with_country(self):
        info = normalize_phone("777304569", expected_country="YE")
        assert info.e164 == "+967777304569"
        assert info.country == "YE"

    def test_saudi_national_number_with_country(self):
        info = normalize_phone("512345678", expected_country="SA")
        assert info.e164 == "+966512345678"
        assert info.country == "SA"

    def test_empty_phone_rejected(self):
        with pytest.raises(ValueError):
            normalize_phone("")

    def test_whitespace_phone_rejected(self):
        with pytest.raises(ValueError):
            normalize_phone("   ")

    def test_garbage_phone_rejected(self):
        with pytest.raises(ValueError):
            normalize_phone("not-a-phone")

    def test_too_short_phone_rejected(self):
        with pytest.raises(ValueError):
            normalize_phone("12345")

    def test_invalid_region_rejected(self):
        with pytest.raises(ValueError):
            normalize_phone("777304569", expected_country="ZZ")

    def test_country_mismatch_rejected(self):
        # A Saudi number must not pass as a Yemeni one.
        with pytest.raises(ValueError):
            normalize_phone("512345678", expected_country="YE")

    def test_country_match_accepted(self):
        info = normalize_phone("512345678", expected_country="SA")
        assert info.country == "SA"

    def test_placeholder_zeroes_rejected(self):
        with pytest.raises(ValueError):
            normalize_phone("0000000000")


class TestIsValidPhone:
    def test_invalid_empty(self):
        assert is_valid_phone(None) is False
        assert is_valid_phone("") is False

    def test_valid_international(self):
        assert is_valid_phone("+967777304569") is True

    def test_valid_with_region(self):
        assert is_valid_phone("777304569", region="YE") is True

    def test_garbage_false(self):
        assert is_valid_phone("12345") is False
        assert is_valid_phone("0000000000") is False


class TestMaskPhone:
    def test_mask_keeps_calling_code_and_last4(self):
        masked = mask_phone("+967777304569")
        assert masked == "+967 *****4569"
        assert "77730" not in masked

    def test_mask_none_for_empty(self):
        assert mask_phone(None) is None
        assert mask_phone("") is None

    def test_mask_coarse_for_unparseable(self):
        masked = mask_phone("abcd1234")
        assert "1234" in masked
