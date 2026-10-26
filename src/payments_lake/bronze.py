"""Capa Bronze: aterrizaje inmutable de los mensajes tal como llegan, más metadatos de ingesta."""
from __future__ import annotations

import json
from datetime import datetime, timezone


def bronze_path(bronze_root: str, ingest_date: str, batch_id: str) -> str:
    return f"{bronze_root}/transactions/ingest_date={ingest_date}/batch_{batch_id}.jsonl"


def to_jsonl(records: list[dict], batch_id: str, source: str, ingest_ts: datetime | None = None) -> str:
    """Serializa el lote sin alterar el payload; sólo agrega columnas técnicas con prefijo '_'."""
    ingest_ts = ingest_ts or datetime.now(timezone.utc)
    meta = {"_batch_id": batch_id, "_ingest_ts": ingest_ts.isoformat(), "_source": source}
    return "".join(json.dumps({**rec, **meta}, ensure_ascii=False) + "\n" for rec in records)


def parse_jsonl(text: str, source_file: str) -> list[dict]:
    """Parsea un archivo bronze. Líneas corruptas se conservan como registro con _parse_error."""
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            rec = {"_parse_error": True}
        rec["_raw"] = line
        rec["_source_file"] = source_file
        rows.append(rec)
    return rows
