import json

from payments_lake import bronze, silver
from payments_lake.generator import build_card_pool

CARD = build_card_pool()[0]


def _rec(**overrides):
    rec = {
        "transaction_id": "t-1",
        "event_ts": "2026-10-20T12:00:00.000Z",
        "acquirer_id": "ACQ-CL-01",
        "pan": CARD["pan"],
        "card_product": "GOLD",
        "card_country": "CL",
        "merchant_id": "M000001",
        "mcc": "5411",
        "merchant_country": "CL",
        "amount": 10000,
        "currency": "CLP",
        "entry_mode": "CHIP",
        "response_code": "00",
        "_batch_id": "b1",
        "_ingest_ts": "2026-10-20T12:05:00+00:00",
    }
    rec.update(overrides)
    rec["_raw"] = json.dumps(rec)
    rec["_source_file"] = "test.jsonl"
    return rec


def test_dedup_keeps_first_arrival():
    first = _rec(_ingest_ts="2026-10-20T12:05:00+00:00", _batch_id="first")
    resend = _rec(_ingest_ts="2026-10-20T13:05:00+00:00", _batch_id="resend")
    out, _, metrics = silver.transform([resend, first], "s")
    assert len(out) == 1 and out.loc[0, "_batch_id"] == "first"
    assert metrics["duplicates_removed"] == 1


def test_invalid_records_go_to_quarantine_with_reasons():
    raw = [
        _rec(transaction_id="ok"),
        _rec(transaction_id="neg", amount=-5),
        _rec(transaction_id="cur", currency="XXX"),
        _rec(transaction_id="ts", event_ts="31/02/2026 25:61"),
        _rec(transaction_id="nomerch", merchant_id=None),
        _rec(transaction_id="luhn", pan=CARD["pan"][:-1] + str((int(CARD["pan"][-1]) + 1) % 10)),
    ]
    out, q, _ = silver.transform(raw, "s")
    assert list(out["transaction_id"]) == ["ok"]
    reasons = dict(zip(q["transaction_id"], q["reject_reasons"]))
    assert reasons == {
        "neg": "non_positive_amount",
        "cur": "unknown_currency",
        "ts": "invalid_timestamp",
        "nomerch": "missing_required_field",
        "luhn": "invalid_pan_luhn",
    }
    assert not q["raw_payload"].str.contains(CARD["pan"]).any()


def test_latam_comma_amount_is_parsed_and_converted_to_usd():
    out, _, _ = silver.transform([_rec(amount="10.000,00")], "s")
    assert out.loc[0, "amount"] == 10000.0
    assert out.loc[0, "amount_usd"] == 10.5  # 10.000 CLP * 0.00105


def test_pan_never_reaches_silver():
    out, _, _ = silver.transform([_rec()], "s")
    assert "pan" not in out.columns
    assert out.loc[0, "pan_last4"] == CARD["pan"][-4:]
    assert CARD["pan"] not in out.astype(str).to_string()


def test_malformed_json_line_is_quarantined():
    rows = bronze.parse_jsonl('{"broken": \n' + json.dumps(_rec()), "f.jsonl")
    out, q, metrics = silver.transform(rows, "s")
    assert len(out) == 1 and metrics["rejected_by_reason"]["malformed_json"] == 1


def test_silver_has_explicit_types_even_for_empty_columns():
    # El simulador no trae card_status ni ip_country: quedan 100 % vacías, pero deben tener tipo
    # (sin tipo, BigQuery no puede registrar la tabla BigLake)
    out, _, _ = silver.transform([_rec()], "s")
    assert out["card_status"].isna().all() and str(out["card_status"].dtype) == "string"
    assert str(out["ip_country"].dtype) == "string"
    assert str(out["fraud_confirmed"].dtype) == "boolean"
    assert not [c for c in out.columns if out[c].dtype == object], "ninguna columna puede quedar como object"
