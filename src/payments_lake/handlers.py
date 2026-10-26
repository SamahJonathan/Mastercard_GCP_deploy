"""Entrypoints HTTP de Cloud Run functions (Python 3.12, Functions Framework).

Las etapas del pipeline las invoca Cloud Workflows con un token OIDC (no son públicas); la API sirve la
capa Gold y se protege con el header x-api-key. Cada función recibe un objeto request de Flask; aquí sólo
se usan .get_json(), .path, .headers y .args, así que los tests pasan un objeto simple.
"""
from __future__ import annotations

import json
import os
from datetime import date
from functools import lru_cache

from . import pipeline, storage
from .config import get_settings, read_secret
from .observability import emit_stage

GOLD_TABLES = {"daily_merchant_kpis", "interchange_settlement", "fraud_alerts", "cross_border_corridors"}
UNPARTITIONED_GOLD = {"fraud_rule_performance"}
JSON_HEADERS = {"content-type": "application/json"}


def _body(request) -> dict:
    return (request.get_json(silent=True) if request is not None else None) or {}


def _ref_date(body: dict) -> date | None:
    value = body.get("ref_date")
    return date.fromisoformat(value) if value else None


def _json(status: int, body) -> tuple[str, int, dict]:
    return json.dumps(body, default=str), status, JSON_HEADERS


def _observed(result: dict) -> tuple[str, int, dict]:
    emit_stage(result)
    return _json(200, result)


def ingest(request):
    size = int(_body(request).get("batch_size") or os.getenv("BATCH_SIZE", "2000"))
    return _observed(pipeline.ingest_batch(size))


def bronze_to_silver(request):
    return _observed(pipeline.bronze_to_silver(_ref_date(_body(request))))


def silver_to_gold(request):
    return _observed(pipeline.silver_to_gold(_ref_date(_body(request))))


# --- API de consumo de la capa Gold --------------------------------------------------------------

@lru_cache(maxsize=1)
def _api_key() -> str:
    return read_secret(os.environ["API_KEY_SECRET_NAME"])


def gold_api(request):
    headers = {k.lower(): v for k, v in (request.headers or {}).items()}
    if headers.get("x-api-key") != _api_key():
        return _json(401, {"error": "unauthorized"})

    path = (request.path or "/").rstrip("/") or "/"
    params = request.args or {}
    st = get_settings()

    if path == "/health":
        return _json(200, {"status": "ok"})
    if path == "/dates":
        return _json(200, storage.list_partitions(f"{st.gold_root}/interchange_settlement", "txn_date"))
    if path.startswith("/gold/"):
        table = path.split("/", 2)[2]
        table_path = f"{st.gold_root}/{table}"
        if table in UNPARTITIONED_GOLD:
            rows = json.loads(storage.read_parquet(table_path).to_json(orient="records"))
            return _json(200, {"table": table, "count": len(rows), "rows": rows})
        if table not in GOLD_TABLES:
            return _json(404, {"error": f"tabla desconocida: {table}", "available": sorted(GOLD_TABLES | UNPARTITIONED_GOLD)})
        day = params.get("date") or (storage.list_partitions(table_path, "txn_date") or [None])[-1]
        if day is None:
            return _json(200, {"table": table, "date": None, "rows": []})
        df = storage.read_parquet(table_path, "txn_date", [day])
        limit = min(int(params.get("limit", "500")), 5000)
        rows = json.loads(df.head(limit).to_json(orient="records", date_format="iso"))
        return _json(200, {"table": table, "date": day, "count": len(df), "rows": rows})
    return _json(404, {"error": "not found", "routes": ["/health", "/dates", "/gold/{table}?date=YYYY-MM-DD&limit=N"]})
