"""Gold con los tipos anulables con que se lee Silver desde Parquet.

Al leer Silver llegan textos 'string' y booleanos 'boolean' anulables. Comparar textos con valores vacíos
da NA, y combinar NA con & fallaba: "boolean value of NA is ambiguous". Fue un bug real (el pipeline
fallaba en silver_to_gold) y este test evita que vuelva.
"""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd

from payments_lake import gold, silver
from payments_lake.generator import generate_batch

ROOT = Path(__file__).resolve().parents[1]


def _silver_nullable() -> pd.DataFrame:
    snap = json.loads((ROOT / "sample_data" / "mastercard_db_ficticia.json").read_text(encoding="utf-8"))
    core, _, _ = silver.transform_core_snapshot(snap, "core.json", "2026-10-21")
    end = datetime(2026, 10, 21, 12, tzinfo=timezone.utc)
    raw = [dict(r, _raw=json.dumps(r), _source_file="f", _ingest_ts=end.isoformat(), _batch_id="b")
           for r in generate_batch(600, end - timedelta(hours=3), end, seed=2)]
    sim, _, _ = silver.transform(raw, "s")
    s = pd.concat([sim, core], ignore_index=True)
    # Como llegan desde Parquet: booleanos anulables y textos anulables
    return s.astype({c: "boolean" for c in s.columns if str(s[c].dtype) == "bool"})


def test_gold_runs_with_nullable_types():
    s = _silver_nullable()
    assert str(s["is_card_present"].dtype) == "boolean"
    assert s["merchant_country"].isna().sum() == 0 and s["ip_country"].isna().any()  # hay vacíos reales
    alerts = gold.fraud_alerts(s)
    assert len(alerts) > 0
    assert len(gold.interchange_settlement(s)) > 0
    assert len(gold.daily_merchant_kpis(s)) > 0
    assert len(gold.cross_border_corridors(s)) > 0
    perf = gold.fraud_rule_performance(s, alerts)
    assert perf.set_index("rule").loc["any_rule", "confirmed_frauds"] > 0
