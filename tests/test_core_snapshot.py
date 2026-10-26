import copy
import json
from pathlib import Path

import pandas as pd

from payments_lake import gold, silver

SNAPSHOT = json.loads((Path(__file__).resolve().parents[1] / "sample_data" / "mastercard_db_ficticia.json").read_text(encoding="utf-8"))


def test_core_snapshot_maps_to_canonical_model():
    out, q, metrics = silver.transform_core_snapshot(SNAPSHOT, "core.json", "2026-10-21")
    assert list(out.columns) == silver.SILVER_COLUMNS
    assert len(out) == len(SNAPSHOT["transacciones"]) and q.empty
    assert set(out["entry_mode"]) <= {"CHIP", "CONTACTLESS", "ECOMMERCE", "MAGSTRIPE"}
    assert out["issuer_name"].notna().all() and out["merchant_name"].notna().all()
    assert (out["source_system"] == "core").all()


def test_core_snapshot_reconciles_with_reported_metrics():
    out, _, _ = silver.transform_core_snapshot(SNAPSHOT, "core.json", "2026-10-21")
    recon = silver.reconcile_core_snapshot(SNAPSHOT, out)
    assert (recon["status"] == "OK").all(), recon


def test_core_snapshot_quarantines_bad_rows():
    snap = copy.deepcopy(SNAPSHOT)
    snap["transacciones"][0]["moneda"] = "XXX"
    snap["transacciones"][1]["token_tarjeta"] = "TKN-NO-EXISTE"
    snap["transacciones"].append(dict(snap["transacciones"][2]))  # duplicado
    out, q, metrics = silver.transform_core_snapshot(snap, "core.json", "2026-10-21")
    assert metrics["duplicates_removed"] == 1
    assert set(q["reject_reasons"]) == {"unknown_currency", "unknown_card_token"}
    assert len(out) == len(SNAPSHOT["transacciones"]) - 2


def test_rule_performance_uses_confirmed_fraud_labels():
    out, _, _ = silver.transform_core_snapshot(SNAPSHOT, "core.json", "2026-10-21")
    perf = gold.fraud_rule_performance(out, gold.fraud_alerts(out)).set_index("rule")
    assert perf.loc["any_rule", "confirmed_frauds"] == int(pd.Series([t["fraude_confirmado"] for t in SNAPSHOT["transacciones"]]).sum())
    assert perf.loc["ip_country_mismatch", "true_positives"] > 0
