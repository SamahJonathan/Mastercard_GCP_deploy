import pytest

from payments_lake.quality import luhn_check_digit, luhn_is_valid, mask_pans, parse_amount, tokenize_pan


def test_luhn_known_test_card():
    assert luhn_is_valid("5555555555554444")
    assert not luhn_is_valid("5555555555554445")
    assert not luhn_is_valid("abcd")


def test_luhn_check_digit_roundtrip():
    partial = "510510123456789"
    assert luhn_is_valid(partial + luhn_check_digit(partial))


@pytest.mark.parametrize(
    "raw, expected",
    [(1234.5, 1234.5), ("1234.5", 1234.5), ("1.234,50", 1234.5), ("12,5", 12.5), ("abc", None), (None, None), (True, None)],
)
def test_parse_amount(raw, expected):
    assert parse_amount(raw) == expected


def test_tokenize_pan_is_stable_and_secret_dependent():
    pan = "5555555555554444"
    assert tokenize_pan(pan, "a") == tokenize_pan(pan, "a")
    assert tokenize_pan(pan, "a") != tokenize_pan(pan, "b")
    assert pan not in tokenize_pan(pan, "a")


def test_mask_pans_keeps_bin_and_last4():
    assert mask_pans('{"pan": "5555555555554444", "amount": 10}') == '{"pan": "555555******4444", "amount": 10}'
    assert mask_pans("ts 20261021 id 123") == "ts 20261021 id 123"
