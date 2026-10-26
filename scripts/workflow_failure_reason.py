#!/usr/bin/env python3
"""Causa legible de una ejecución fallida de Cloud Workflows, para que el registro del despliegue se baste solo.

    gcloud workflows executions describe <id> --workflow ... --format=json | python scripts/workflow_failure_reason.py
    -> "etapa silver_to_gold: HTTP 500: boolean value of NA is ambiguous"
"""
from __future__ import annotations

import json
import sys


def failure_reason(execution: dict) -> str:
    error = execution.get("error") or {}
    frames = (error.get("stackTrace") or {}).get("elements") or []
    # El primer marco es el más interno (run_stage); el de main dice qué etapa estaba corriendo
    main_frames = [f for f in frames if f.get("routine") == "main"]
    stage = (main_frames or frames or [{}])[0].get("step", "?")
    payload = error.get("payload") or ""
    try:
        data = json.loads(payload)
    except (TypeError, json.JSONDecodeError):
        return f"etapa {stage}: {payload or error.get('context') or 'sin detalle'}"
    if isinstance(data, dict):
        code = data.get("code")
        body = data.get("body")
        detail = body.get("error") if isinstance(body, dict) else body
        message = detail or data.get("message") or payload
        return f"etapa {stage}: " + (f"HTTP {code}: {message}" if code else str(message))
    return f"etapa {stage}: {data}"


if __name__ == "__main__":
    print(failure_reason(json.load(sys.stdin)))
