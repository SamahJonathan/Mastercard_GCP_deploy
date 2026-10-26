import json
from types import SimpleNamespace

from payments_lake import handlers, pipeline
from payments_lake.config import Settings


def _request(path, key="secret", **args):
    """Lo mínimo del request de Flask que usa la API: path, headers y args."""
    return SimpleNamespace(path=path, headers={"X-Api-Key": key}, args=args, get_json=lambda silent=True: None)


def test_api_requires_key_and_serves_gold(tmp_path, monkeypatch):
    root = str(tmp_path).replace("\\", "/")
    st = Settings(f"{root}/bronze", f"{root}/silver", f"{root}/gold", f"{root}/exchange", None, None, 3, "t")
    pipeline.ingest_core_snapshot(pipeline.SAMPLE_SNAPSHOT, st)
    pipeline.bronze_to_silver(None, st)
    pipeline.silver_to_gold(None, st)
    monkeypatch.setattr(handlers, "get_settings", lambda: st)
    monkeypatch.setattr(handlers, "_api_key", lambda: "secret")

    def call(path, key="secret", **qs):
        body, status, headers = handlers.gold_api(_request(path, key, **qs))
        assert headers["content-type"] == "application/json"
        return status, json.loads(body)

    assert call("/health", key="wrong")[0] == 401
    status, kpis = call("/gold/daily_merchant_kpis", date="2026-09-15")
    assert status == 200 and kpis["date"] == "2026-09-15" and kpis["count"] > 0
    _, perf = call("/gold/fraud_rule_performance")
    assert {r["rule"] for r in perf["rows"]} >= {"velocity", "any_rule"}
    assert call("/gold/nope")[0] == 404


def test_stage_handlers_read_json_body(monkeypatch):
    seen = {}
    monkeypatch.setattr(pipeline, "bronze_to_silver", lambda ref_date: seen.setdefault("date", ref_date) and {"stage": "x"})
    monkeypatch.setattr(handlers, "emit_stage", lambda result: None)
    req = SimpleNamespace(get_json=lambda silent=True: {"ref_date": "2026-10-21"})
    body, status, _ = handlers.bronze_to_silver(req)
    assert status == 200 and str(seen["date"]) == "2026-10-21"
