"""Orquestación de las etapas. Lo usan tanto la CLI local como los handlers de Cloud Run functions.

    python -m payments_lake.pipeline demo --days 3      # genera datos y corre bronze -> silver -> gold en ./data
"""
from __future__ import annotations

import argparse
import json
import os
from datetime import date, datetime, timedelta, timezone

import pandas as pd

from . import bronze, generator, gold, silver, storage
from . import reference as ref
from .config import Settings, get_settings

SAMPLE_SNAPSHOT = os.path.join(os.path.dirname(__file__), "..", "..", "sample_data", "mastercard_db_ficticia.json")


def _window(ref_date: date, lookback_days: int) -> list[str]:
    return [(ref_date - timedelta(days=d)).isoformat() for d in range(lookback_days, -1, -1)]


# --- Ingesta (-> Bronze) -----------------------------------------------------------------------

def ingest_batch(
    n: int = 2000,
    window_start: datetime | None = None,
    window_end: datetime | None = None,
    settings: Settings | None = None,
    seed: int | None = None,
    source: str = "simulator",
) -> dict:
    """Simula la llegada de un archivo de un adquirente y lo aterriza en Bronze."""
    st = settings or get_settings()
    window_end = window_end or datetime.now(timezone.utc)
    window_start = window_start or window_end - timedelta(hours=1)
    records = generator.generate_batch(n, window_start, window_end, seed=seed)
    batch_id = generator.new_batch_id()
    ingest_ts = max(window_end, window_start)
    path = bronze.bronze_path(st.bronze_root, ingest_ts.date().isoformat(), batch_id)
    storage.write_text(path, bronze.to_jsonl(records, batch_id, source, ingest_ts))
    return {"stage": "ingest", "batch_id": batch_id, "path": path, "records": len(records)}


def ingest_core_snapshot(local_path: str = SAMPLE_SNAPSHOT, settings: Settings | None = None) -> dict:
    """Aterriza tal cual (sin modificar) el extracto del sistema core en Bronze."""
    st = settings or get_settings()
    with open(local_path, encoding="utf-8") as fh:
        text = fh.read()
    today = datetime.now(timezone.utc).date().isoformat()
    path = f"{st.bronze_root}/core_snapshot/ingest_date={today}/{os.path.basename(local_path)}"
    storage.write_text(path, text)
    return {"stage": "ingest_core_snapshot", "path": path, "bytes": len(text.encode("utf-8"))}


# --- Bronze -> Silver ----------------------------------------------------------------------------

def _latest_core_snapshot(st: Settings) -> tuple[str, str] | None:
    """El extracto core es una carga completa: sólo importa el más reciente."""
    files = storage.list_files(f"{st.bronze_root}/core_snapshot", ".json")
    if not files:
        return None
    latest = max(files, key=lambda f: (f.replace("\\", "/").split("ingest_date=")[-1], f))
    ingest_date = latest.replace("\\", "/").split("ingest_date=")[-1].split("/")[0]
    return latest, ingest_date


def _load_core(st: Settings) -> tuple[dict, str, str, str] | None:
    """Fuente core: si existe la réplica de Datastream (backfill + CDC) tiene prioridad sobre el extracto JSON.

    Devuelve (snapshot, source_file, ingest_ts, channel).
    """
    ds_root = f"{st.bronze_root}/datastream"
    files = storage.list_files(ds_root, ".jsonl")
    if files:
        events = [json.loads(line) for f in files for line in storage.read_text(f).splitlines() if line.strip()]
        snapshot = silver.datastream_to_snapshot(events)
        if snapshot.get("transacciones"):
            return snapshot, ds_root, datetime.now(timezone.utc).isoformat(), "datastream_cdc"
    latest = _latest_core_snapshot(st)
    if latest:
        path, ingest_date = latest
        return json.loads(storage.read_text(path)), path, ingest_date, "file_snapshot"
    return None


def bronze_to_silver(ref_date: date | None = None, settings: Settings | None = None) -> dict:
    st = settings or get_settings()
    ref_date = ref_date or datetime.now(timezone.utc).date()
    dates = _window(ref_date, st.lookback_days)
    silver_tx = f"{st.silver_root}/transactions"
    result = {"stage": "bronze_to_silver", "window": [dates[0], dates[-1]], "sources": []}
    quarantines = []

    # Fuente 1: simulador (incremental por ventana de ingest_date)
    table = f"{st.bronze_root}/transactions"
    raw = []
    for d in sorted(set(dates) & set(storage.list_partitions(table, "ingest_date"))):
        for f in storage.list_files(f"{table}/ingest_date={d}", ".jsonl"):
            raw.extend(bronze.parse_jsonl(storage.read_text(f), f))
    clean, quarantine, metrics = silver.transform(raw, st.pan_token_secret)
    # Sólo se reescriben fechas de transacción completamente cubiertas por la ventana (idempotente ante reprocesos)
    clean = clean[clean["txn_date"] >= dates[0]]
    storage.write_parquet(clean, silver_tx, ["source_system", "txn_date"], st.bq_dataset_silver, "transactions")
    quarantines.append(quarantine)
    result["sources"].append({**metrics, "silver_written": len(clean)})

    # Fuente 2: sistema core (réplica Datastream o extracto JSON; ambas son cargas completas)
    loaded = _load_core(st)
    if loaded:
        snapshot, path, ingest_ts, channel = loaded
        core, core_q, core_metrics = silver.transform_core_snapshot(snapshot, path, ingest_ts, channel)
        storage.write_parquet(core, silver_tx, ["source_system", "txn_date"], st.bq_dataset_silver, "transactions")
        quarantines.append(core_q)
        if "metricas_resumen" in snapshot:  # sólo el extracto declara totales de control
            recon = silver.reconcile_core_snapshot(snapshot, core).assign(source_file=path, checked_at=datetime.now(timezone.utc).isoformat())
            storage.write_parquet(recon, f"{st.silver_root}/dq_source_reconciliation", None, st.bq_dataset_silver, "dq_source_reconciliation")
            core_metrics["reconciliation"] = dict(zip(recon["metric"], recon["status"]))
        result["sources"].append({**core_metrics, "silver_written": len(core)})

    non_empty = [q for q in quarantines if not q.empty]
    if non_empty:
        quarantine = pd.concat(non_empty, ignore_index=True).astype("string").assign(ingest_date=ref_date.isoformat())
        storage.write_parquet(quarantine, f"{st.silver_root}/quarantine", ["ingest_date"], st.bq_dataset_silver, "quarantine")

    # Dimensiones de referencia (pequeñas, se reescriben completas)
    storage.write_parquet(ref.build_merchants(), f"{st.silver_root}/dim_merchant", None, st.bq_dataset_silver, "dim_merchant")
    storage.write_parquet(ref.issuers_frame(), f"{st.silver_root}/dim_issuer", None, st.bq_dataset_silver, "dim_issuer")
    return result


# --- Silver -> Gold ------------------------------------------------------------------------------

def silver_to_gold(ref_date: date | None = None, settings: Settings | None = None) -> dict:
    st = settings or get_settings()
    ref_date = ref_date or datetime.now(timezone.utc).date()
    silver_tx = f"{st.silver_root}/transactions"
    # Fechas a recalcular: la ventana del flujo en línea + los días que cubre el extracto core
    core_dates = storage.list_partitions(f"{silver_tx}/source_system=core", "txn_date")
    dates = sorted(set(_window(ref_date, st.lookback_days)) | set(core_dates))
    s = storage.read_parquet(silver_tx, "txn_date", dates)
    if s.empty:
        return {"stage": "silver_to_gold", "silver_records": 0}

    tables = {
        "daily_merchant_kpis": gold.daily_merchant_kpis(s),
        "interchange_settlement": gold.interchange_settlement(s),
        "fraud_alerts": gold.fraud_alerts(s),
        "cross_border_corridors": gold.cross_border_corridors(s),
    }
    for name, df in tables.items():
        storage.write_parquet(df, f"{st.gold_root}/{name}", ["txn_date"], st.bq_dataset_gold, name)

    # Desempeño de las reglas de fraude contra los fraudes confirmados (sólo fuentes con etiqueta)
    perf = gold.fraud_rule_performance(s, tables["fraud_alerts"])
    storage.write_parquet(perf, f"{st.gold_root}/fraud_rule_performance", None, st.bq_dataset_gold, "fraud_rule_performance")

    # Intercambio de datos saliente: un archivo de liquidación + manifiesto por emisor y día
    files = gold.issuer_settlement_files(tables["interchange_settlement"])
    for issuer_id, d, csv_text, manifest in files:
        base = f"{st.exchange_root}/outbound/issuer_id={issuer_id}/settlement_date={d}"
        storage.write_text(f"{base}/settlement.csv", csv_text)
        storage.write_text(f"{base}/_manifest.json", manifest)

    return {
        "stage": "silver_to_gold",
        "silver_records": len(s),
        "dates": [dates[0], dates[-1]],
        **{f"{k}_rows": len(v) for k, v in tables.items()},
        "fraud_rule_performance": perf.astype(object).where(perf.notna(), None).to_dict("records"),
        "exchange_files": len(files),
        "total_interchange_usd": round(float(tables["interchange_settlement"]["interchange_fee_usd"].sum()), 2),
    }


def run_demo(days: int, batches_per_day: int, batch_size: int, with_core: bool = True) -> list[dict]:
    st = get_settings()
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    results = []
    if with_core and os.path.exists(SAMPLE_SNAPSHOT):
        results.append(ingest_core_snapshot(SAMPLE_SNAPSHOT, st))
    for d in range(days - 1, -1, -1):
        day_start = (now - timedelta(days=d)).replace(hour=0)
        for b in range(batches_per_day):
            start = day_start + timedelta(hours=b * 24 / batches_per_day)
            end = start + timedelta(hours=24 / batches_per_day)
            results.append(ingest_batch(batch_size, start, min(end, now + timedelta(hours=1)), st, seed=d * 100 + b))
    results.append(bronze_to_silver(now.date(), st))
    results.append(silver_to_gold(now.date(), st))
    return results


def main() -> None:
    p = argparse.ArgumentParser(description="Payments Lakehouse - ejecución local")
    sub = p.add_subparsers(dest="cmd", required=True)
    demo = sub.add_parser("demo", help="genera N días de datos, carga el extracto core y corre todo el pipeline")
    demo.add_argument("--days", type=int, default=3)
    demo.add_argument("--batches-per-day", type=int, default=4)
    demo.add_argument("--batch-size", type=int, default=1500)
    demo.add_argument("--no-core", action="store_true", help="no cargar sample_data/mastercard_db_ficticia.json")
    sub.add_parser("ingest", help="aterriza un lote simulado nuevo en bronze")
    snap = sub.add_parser("ingest-core", help="aterriza un extracto core (JSON) en bronze")
    snap.add_argument("path", nargs="?", default=SAMPLE_SNAPSHOT)
    sub.add_parser("silver", help="bronze -> silver")
    sub.add_parser("gold", help="silver -> gold")
    args = p.parse_args()

    if args.cmd == "demo":
        out = run_demo(args.days, args.batches_per_day, args.batch_size, with_core=not args.no_core)
    elif args.cmd == "ingest":
        out = ingest_batch()
    elif args.cmd == "ingest-core":
        out = ingest_core_snapshot(args.path)
    elif args.cmd == "silver":
        out = bronze_to_silver()
    else:
        out = silver_to_gold()
    print(json.dumps(out, indent=2, default=str, ensure_ascii=False))


if __name__ == "__main__":
    main()
