from datetime import datetime, timedelta, timezone

from payments_lake import pipeline, storage
from payments_lake.config import Settings


def _settings(tmp_path):
    root = str(tmp_path).replace("\\", "/")
    return Settings(
        bronze_root=f"{root}/bronze", silver_root=f"{root}/silver", gold_root=f"{root}/gold",
        exchange_root=f"{root}/exchange", bq_dataset_silver=None, bq_dataset_gold=None,
        lookback_days=2, pan_token_secret="test",
    )


def _written(result):
    return {s["source_system"]: s["silver_written"] for s in result["sources"]}


def test_end_to_end_both_sources_is_idempotent(tmp_path):
    st = _settings(tmp_path)
    end = datetime(2026, 10, 20, 18, tzinfo=timezone.utc)
    pipeline.ingest_batch(800, end - timedelta(hours=6), end, st, seed=1)
    pipeline.ingest_core_snapshot(pipeline.SAMPLE_SNAPSHOT, st)

    first = pipeline.bronze_to_silver(end.date(), st)
    gold1 = pipeline.silver_to_gold(end.date(), st)
    # Reprocesar no debe duplicar datos
    second = pipeline.bronze_to_silver(end.date(), st)
    gold2 = pipeline.silver_to_gold(end.date(), st)

    written = _written(first)
    assert written == _written(second)
    assert written["simulator"] > 0 and written["core"] == 1500
    assert len(storage.read_parquet(f"{st.silver_root}/transactions")) == sum(written.values())
    assert gold1 == gold2
    assert gold1["dates"][0] == "2026-09-01"  # gold también cubre el mes del extracto core
    assert storage.list_files(f"{st.exchange_root}/outbound", "_manifest.json")
