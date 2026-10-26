import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("deploy_record", ROOT / "scripts" / "deploy_record.py")
deploy_record = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(deploy_record)

SECRET = "s3cr3t-password-value"

PLAN = {
    "resource_changes": [
        {"address": "google_storage_bucket.layer[\"bronze\"]", "type": "google_storage_bucket", "change": {"actions": ["create"], "after": {"name": "b"}}},
        {"address": "random_password.core_db[0]", "type": "random_password", "change": {"actions": ["create"], "after": {"result": SECRET}}},
        {"address": "google_cloudfunctions2_function.fn[\"api\"]", "type": "google_cloudfunctions2_function", "change": {"actions": ["update"], "after": {"service_config": [{"environment_variables": {"KEY": SECRET}}]}}},
        {"address": "google_workflows_workflow.gold_analytics", "type": "google_workflows_workflow", "change": {"actions": ["delete", "create"]}},
        {"address": "google_service_account.this[\"old\"]", "type": "google_service_account", "change": {"actions": ["delete"]}},
        {"address": "google_kms_crypto_key.lake", "type": "google_kms_crypto_key", "change": {"actions": ["no-op"]}},
        {"address": "data.google_project.this", "type": "google_project", "change": {"actions": ["read"]}},
    ]
}


def test_summary_counts_like_terraform_plan():
    summary, resources = deploy_record.summarize_plan(PLAN)
    # el reemplazo cuenta como +1 y -1, igual que "Plan: X to add, Y to change, Z to destroy"
    assert (summary["add"], summary["change"], summary["destroy"], summary["replace"]) == (3, 1, 2, 1)
    assert summary["by_type"]["google_storage_bucket"] == 1
    assert len(resources) == 5  # no-op y read no se listan


def test_summary_never_contains_values():
    summary, resources = deploy_record.summarize_plan(PLAN)
    dumped = json.dumps([summary, resources])
    assert SECRET not in dumped
    assert all(set(r) == {"address", "type", "actions"} for r in resources)


def test_dry_run_writes_local_record(tmp_path, capsys):
    rc = deploy_record.main([
        "--deployment-id", "20261021-120000-abc1234", "--status", "failed", "--failed-step", "5/6 Plan",
        "--error", "x" * 2000, "--started-at", "2026-10-21T12:00:00Z", "--out-dir", str(tmp_path), "--dry-run",
    ])
    assert rc == 0
    record = json.loads((tmp_path / "20261021-120000-abc1234.json").read_text(encoding="utf-8"))
    assert record["result"] == "failed" and record["failed_step"] == "5/6 Plan"
    assert len(record["error"]) == 500  # recortado
    assert record["schema_version"] == 1 and record["duration_s"] >= 0
    assert "solo copia local" in capsys.readouterr().out


def test_record_failure_never_breaks_deploy(tmp_path, capsys):
    # started-at inválido provoca una excepción interna: el script avisa y sale con 0
    rc = deploy_record.main(["--deployment-id", "x", "--status", "success", "--started-at", "no-es-fecha",
                             "--out-dir", str(tmp_path), "--dry-run"])
    assert rc == 0
    assert "AVISO" in capsys.readouterr().out


def test_gcs_prefix_is_partitioned_by_day():
    assert deploy_record.gcs_prefix({"finished_at": "2026-10-21T20:00:00+00:00", "deployment_id": "abc"}) == "deployments/2026/10/21/abc"


def test_workflow_failure_reason_from_real_execution_shape():
    spec = importlib.util.spec_from_file_location("workflow_failure_reason", ROOT / "scripts" / "workflow_failure_reason.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # Forma real de `gcloud workflows executions describe --format=json` cuando una function responde 500
    execution = {"state": "FAILED", "error": {
        "payload": json.dumps({"code": 500, "message": "HTTP server responded with error code 500",
                               "body": "boolean value of NA is ambiguous"}),
        "context": "RuntimeError",
        "stackTrace": {"elements": [
            {"routine": "run_stage", "step": "call_stage", "position": {"line": 52}},
            {"routine": "main", "step": "silver_to_gold", "position": {"line": 38}},
        ]},
    }}
    assert mod.failure_reason(execution) == "etapa silver_to_gold: HTTP 500: boolean value of NA is ambiguous"
    assert mod.failure_reason({"error": {"payload": "texto plano", "stackTrace": {}}}) == "etapa ?: texto plano"
