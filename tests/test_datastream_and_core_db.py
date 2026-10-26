import importlib.util
import json
import uuid
from datetime import datetime
from pathlib import Path

from payments_lake import observability, pipeline, silver, storage
from payments_lake.config import Settings

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = json.loads((ROOT / "sample_data" / "mastercard_db_ficticia.json").read_text(encoding="utf-8"))

_spec = importlib.util.spec_from_file_location("load_core_db", ROOT / "scripts" / "core_db" / "load_core_db.py")
load_core_db = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(load_core_db)


def _settings(tmp_path):
    root = str(tmp_path).replace("\\", "/")
    return Settings(f"{root}/bronze", f"{root}/silver", f"{root}/gold", f"{root}/exchange", None, None, 2, "t")


def _event(table, row, change, ts, lsn=None, method="postgresql-cdc-logical-decoding"):
    """Una línea JSONL como la escribe Datastream (formato JSON, origen PostgreSQL)."""
    payload = dict(row)
    if "fecha_hora" in payload:  # Datastream entrega TIMESTAMP como texto ISO-8601
        payload["fecha_hora"] = payload["fecha_hora"] + ".000000Z"
    for col in ("monto", "monto_usd"):  # y NUMERIC como texto, para no perder precisión
        if payload.get(col) is not None:
            payload[col] = str(payload[col])
    return {
        "uuid": str(uuid.uuid4()),
        "read_timestamp": ts,
        "source_timestamp": ts,
        "object": f"core_{table}",
        "read_method": method,
        "stream_name": "projects/p/locations/southamerica-east1/streams/paylake-dev-core",
        "schema_key": "abc",
        "sort_keys": [ts, lsn or ""],
        "source_metadata": {
            "schema": "core", "table": table, "is_deleted": change == "DELETE", "change_type": change,
            "tx_id": 1, "lsn": lsn, "primary_keys": [silver.CORE_PRIMARY_KEYS[table]],
        },
        "payload": payload,
    }


def _write(st, table, name, events):
    """Layout real de Datastream en GCS: <prefijo>/<schema>_<tabla>/AAAA/MM/DD/HH/mm/<archivo>.jsonl"""
    path = Path(st.bronze_root) / "datastream" / f"core_{table}" / "2026" / "10" / "21" / "10" / "00"
    path.mkdir(parents=True, exist_ok=True)
    (path / name).write_text("".join(json.dumps(e) + "\n" for e in events), encoding="utf-8")


def test_datastream_backfill_plus_cdc_wins_over_file_snapshot(tmp_path):
    st = _settings(tmp_path)
    pipeline.ingest_core_snapshot(pipeline.SAMPLE_SNAPSHOT, st)  # existe el extracto, pero Datastream tiene prioridad
    for table in load_core_db.PRIMARY_KEYS:
        events = [_event(table, r, "INSERT", "2026-10-21T10:00:00.000Z", method="postgresql-backfill-fulldump")
                  for r in SNAPSHOT[table]]
        _write(st, table, "backfill.jsonl", events)

    txns = SNAPSHOT["transacciones"]
    updated = dict(txns[0], contracargo=True)
    deleted = dict(txns[1])
    new = dict(txns[2], transaccion_id="TXC-NEW-1", fecha_hora="2026-10-21T09:30:00")
    # Mismo instante: el LSN decide el orden (el UPDATE que gana es el de LSN mayor)
    stale = dict(txns[0], contracargo=False)
    _write(st, "transacciones", "cdc.jsonl", [
        _event("transacciones", updated, "UPDATE", "2026-10-21T11:00:00.000Z", lsn="0/1A0"),
        _event("transacciones", stale, "UPDATE", "2026-10-21T11:00:00.000Z", lsn="0/19F"),
        _event("transacciones", deleted, "DELETE", "2026-10-21T11:00:01.000Z", lsn="0/1B0"),
        _event("transacciones", new, "INSERT", "2026-10-21T11:00:02.000Z", lsn="0/1C0"),
    ])

    result = pipeline.bronze_to_silver(datetime(2026, 10, 21).date(), st)
    core = next(s for s in result["sources"] if s["source_system"] == "core")
    assert core["channel"] == "datastream_cdc"
    assert core["silver_written"] == len(txns)  # -1 borrada, +1 nueva

    out = storage.read_parquet(f"{st.silver_root}/transactions")
    ids = set(out["transaction_id"])
    assert "TXC-NEW-1" in ids and deleted["transaccion_id"] not in ids
    assert bool(out.loc[out["transaction_id"] == updated["transaccion_id"], "chargeback"].iloc[0])


def test_datastream_values_are_normalized():
    row = dict(SNAPSHOT["transacciones"][0], wallet="t", fraude_confirmado="false", actualizado_en="x")
    snap = silver.datastream_to_snapshot([_event("transacciones", row, "INSERT", "2026-10-21T10:00:00Z")])
    [t] = snap["transacciones"]
    assert t["wallet"] is True and t["fraude_confirmado"] is False
    assert t["fecha_hora"] == SNAPSHOT["transacciones"][0]["fecha_hora"]  # sin zona: hora de pared
    assert isinstance(t["monto"], float) and "actualizado_en" not in t
    # Timestamps como microsegundos epoch también se aceptan
    assert silver._core_ts(1_760_000_000_000_000) == "2025-10-09T08:53:20"


def test_core_db_init_sql_prepares_logical_replication():
    sql = load_core_db.init_sql(SNAPSHOT)
    for table in load_core_db.PRIMARY_KEYS:
        assert f"INSERT INTO core.{table}" in sql
    assert "ALTER ROLE CURRENT_USER WITH REPLICATION" in sql
    assert "CREATE PUBLICATION paylake_pub FOR TABLES IN SCHEMA core" in sql
    # El slot se crea después del COMMIT de la carga (no puede ir en una transacción que ya escribió)
    assert sql.index("pg_create_logical_replication_slot") > sql.index("COMMIT;")
    assert load_core_db.literal("O'Higgins") == "'O''Higgins'"
    assert load_core_db.literal(None) == "NULL" and load_core_db.literal(True) == "TRUE"


def test_core_db_cdc_generates_inserts_and_late_updates():
    sql = load_core_db.cdc_sql(SNAPSHOT, new=5, now=datetime(2026, 10, 21, 12), seed=3)
    assert sql.count("'TXC") == 5
    assert "SET contracargo = TRUE" in sql and "SET fraude_confirmado = TRUE" in sql


def test_metrics_only_inside_cloud_run(monkeypatch, capsys):
    assert observability.emit({"stage": "x"}, {"Rows": 1}) is None
    monkeypatch.setenv("K_SERVICE", "paylake-dev-bronze-to-silver")
    monkeypatch.delenv("GCP_PROJECT", raising=False)  # sin proyecto: sólo el log estructurado
    payload = observability.emit({"stage": "x", "source": "core"}, {"Rows": 3, "InterchangeUsd": 1.5})
    printed = json.loads(capsys.readouterr().out)
    assert printed == payload and printed["severity"] == "INFO"
    assert printed["paylake_metrics"] == {"stage": "x", "source": "core", "Rows": 3.0, "InterchangeUsd": 1.5}
    assert observability.metric_type("RejectedRecords") == "custom.googleapis.com/paylake/rejected_records"


def test_stage_metrics_include_rejection_rate(monkeypatch):
    sent = []
    monkeypatch.setattr(observability, "emit", lambda dims, metrics: sent.append((dims, metrics)))
    observability.emit_stage({"stage": "bronze_to_silver", "sources": [
        {"source_system": "simulator", "bronze_records": 200, "rejected_records": 10, "silver_written": 190},
    ]})
    [(dims, metrics)] = sent
    assert dims == {"stage": "bronze_to_silver", "source": "simulator"}
    assert metrics["RejectionRate"] == 0.05
