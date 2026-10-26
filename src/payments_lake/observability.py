"""Métricas de negocio y calidad hacia Cloud Monitoring (métricas propias custom.googleapis.com/paylake/*).

En Cloud Run functions cada métrica se escribe dos veces:
  - como log estructurado (JSON en stdout): Cloud Logging lo guarda en jsonPayload, consultable con filtros
  - como serie de tiempo en Cloud Monitoring: alimenta el dashboard y las alertas de calidad de datos
Fuera de GCP (sin K_SERVICE) no hace nada. Las métricas nunca rompen el pipeline.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time

METRIC_PREFIX = "custom.googleapis.com/paylake"


def metric_type(name: str) -> str:
    """RejectedRecords -> custom.googleapis.com/paylake/rejected_records"""
    return f"{METRIC_PREFIX}/{re.sub(r'(?<!^)(?=[A-Z])', '_', name).lower()}"


def emit(dimensions: dict[str, str], metrics: dict[str, float]) -> dict | None:
    if not os.getenv("K_SERVICE"):
        return None
    values = {k: float(v) for k, v in metrics.items() if v is not None}
    payload = {
        "severity": "INFO",
        "message": f"paylake metrics {dimensions.get('stage')}/{dimensions.get('source')}",
        "paylake_metrics": {**dimensions, **values},
    }
    print(json.dumps(payload), flush=True)
    _write_time_series(dimensions, values)
    return payload


def _write_time_series(dimensions: dict[str, str], values: dict[str, float]) -> None:
    project = os.getenv("GCP_PROJECT")
    if not project or not values:
        return
    try:
        from google.cloud import monitoring_v3

        now = time.time()
        interval = monitoring_v3.TimeInterval({"end_time": {"seconds": int(now), "nanos": int((now % 1) * 1e9)}})
        series = []
        for name, value in values.items():
            ts = monitoring_v3.TimeSeries()
            ts.metric.type = metric_type(name)
            ts.metric.labels.update({**dimensions, "environment": os.getenv("ENVIRONMENT", "dev")})
            ts.resource.type = "global"
            ts.resource.labels["project_id"] = project
            ts.points = [monitoring_v3.Point({"interval": interval, "value": {"double_value": value}})]
            series.append(ts)
        monitoring_v3.MetricServiceClient().create_time_series(name=f"projects/{project}", time_series=series)
    except Exception as exc:  # las métricas nunca rompen el pipeline
        print(json.dumps({"severity": "WARNING", "message": f"no se pudieron escribir métricas: {exc}"}), file=sys.stderr)


def emit_stage(result: dict) -> None:
    """Traduce el resultado de cada etapa del pipeline a métricas."""
    stage = result.get("stage", "unknown")
    if stage == "ingest":
        emit({"stage": stage, "source": "simulator"}, {"IngestedRecords": result.get("records")})
    elif stage == "bronze_to_silver":
        for src in result.get("sources", []):
            recon = src.get("reconciliation", {})
            bronze = src.get("bronze_records") or 0
            rejected = src.get("rejected_records", 0)
            emit(
                {"stage": stage, "source": src["source_system"]},
                {
                    "BronzeRecords": bronze,
                    "SilverRecords": src.get("silver_written"),
                    "RejectedRecords": rejected,
                    "DuplicatesRemoved": src.get("duplicates_removed", 0),
                    # La tasa se calcula aquí: la alerta compara directo contra el umbral
                    "RejectionRate": round(rejected / bronze, 4) if bronze else 0.0,
                    "ReconciliationMismatches": sum(1 for v in recon.values() if v != "OK"),
                },
            )
    elif stage == "silver_to_gold":
        emit(
            {"stage": stage, "source": "all"},
            {
                "SilverRecords": result.get("silver_records"),
                "FraudAlerts": result.get("fraud_alerts_rows"),
                "ExchangeFiles": result.get("exchange_files"),
                "InterchangeUsd": result.get("total_interchange_usd"),
            },
        )
