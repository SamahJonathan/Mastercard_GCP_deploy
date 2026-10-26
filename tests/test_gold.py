import pandas as pd
import pytest

from payments_lake import gold


def _silver(rows):
    base = {
        "txn_date": "2026-10-20", "issuer_id": "EM001", "issuer_name": "Banco Andino",
        "acquirer_id": "ACQ-CL-01", "pan_token": "tok", "pan_last4": "4444", "card_product": "STANDARD",
        "card_country": "CL", "merchant_id": "M1", "merchant_name": "X", "mcc": "5812", "mcc_category": "dining",
        "merchant_country": "CL", "entry_mode": "CHIP", "is_card_present": True, "is_cross_border": False,
        "amount_usd": 100.0, "is_approved": True,
    }
    df = pd.DataFrame([{**base, **r} for r in rows])
    df["transaction_id"] = [f"t{i}" for i in range(len(df))]
    df["event_ts"] = pd.to_datetime(df["event_ts"])
    return df


def test_interchange_fee_domestic_vs_cross_border():
    s = _silver([
        {"event_ts": "2026-10-20 10:00"},
        {"event_ts": "2026-10-20 11:00", "is_cross_border": True, "pan_token": "other"},
        {"event_ts": "2026-10-20 12:00", "is_approved": False},  # rechazada: no genera intercambio
    ])
    fees = gold.with_interchange(s)["interchange_fee_usd"].tolist()
    assert fees == [pytest.approx(100 * 0.012 + 0.05), pytest.approx(100 * 0.022 + 0.05)]


def test_velocity_rule_triggers_on_burst():
    s = _silver([{"event_ts": f"2026-10-20 10:0{i}"} for i in range(5)] + [{"event_ts": "2026-10-20 18:00"}])
    alerts = gold.fraud_alerts(s)
    assert alerts["rules"].tolist() == ["velocity"]
    assert alerts.loc[0, "txn_count_10m"] == 5


def test_impossible_travel_requires_card_present_in_two_countries():
    s = _silver([
        {"event_ts": "2026-10-20 10:00", "merchant_country": "CL"},
        {"event_ts": "2026-10-20 10:30", "merchant_country": "ES"},
        {"event_ts": "2026-10-20 10:40", "merchant_country": "US", "entry_mode": "ECOMMERCE", "is_card_present": False},
    ])
    alerts = gold.fraud_alerts(s)
    assert alerts["rules"].tolist() == ["impossible_travel"]
    assert alerts.loc[0, "merchant_country"] == "ES"


def test_settlement_files_have_valid_manifest():
    import hashlib
    import json

    settlement = gold.interchange_settlement(_silver([{"event_ts": "2026-10-20 10:00"}]))
    [(issuer, day, csv_text, manifest)] = gold.issuer_settlement_files(settlement)
    m = json.loads(manifest)
    assert (issuer, day, m["record_count"]) == ("EM001", "2026-10-20", 1)
    assert m["sha256"] == hashlib.sha256(csv_text.encode()).hexdigest()
