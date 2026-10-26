# Observabilidad de los despliegues

Además de observar los **datos** (métricas de calidad, alertas del pipeline), el proyecto observa el **proceso de
despliegue**: cada `deploy`, `pause` o `destroy`, desde el PC o desde GitHub Actions, deja un registro con el mismo
formato y en el mismo lugar.

## Dónde queda

| Lugar | Qué | Retención |
|---|---|---|
| Cloud Logging, log `paylake-deployments` | el registro completo como `jsonPayload` | 1 año (log bucket `paylake-deployments` del bootstrap: sobrevive a un `destroy`) |
| `gs://<proyecto>-tfstate/deployments/AAAA/MM/DD/<id>.json` | el mismo registro | versionado con el estado |
| `…/<id>.plan.json` | direcciones y acciones del plan de Terraform (**sin valores**) | |
| `…/<id>.log` | el transcript completo de PowerShell | |
| `logs/` en el PC | copia local | fuera de git |

Lo escribe [`scripts/deploy_record.py`](../scripts/deploy_record.py), que llaman `deploy.ps1`, `destroy.ps1` y
`.github/workflows/deploy.yml`. Es "mejor esfuerzo": si el registro falla, avisa pero nunca rompe el despliegue.

## Qué guarda

```json
{
  "deployment_id": "20261026-191500-a1b2c3d",
  "kind": "deploy",
  "result": "failed",
  "failed_step": "Smoke test: ejecutando el pipeline en Cloud Workflows",
  "error": "El pipeline terminó en FAILED: etapa silver_to_gold: HTTP 500: boolean value of NA is ambiguous",
  "source": "local",
  "actor": {"gcp_account": "...", "git_user": "...", "host": "..."},
  "git": {"commit_short": "a1b2c3d", "branch": "main", "dirty": false},
  "plan": {"add": 3, "change": 1, "destroy": 0, "replace": 0, "by_type": {"google_cloudfunctions2_function": 1}},
  "pipeline": {"execution": "projects/.../executions/...", "status": "FAILED"},
  "iam_checks": "passed",
  "duration_s": 412.7
}
```

`terraform show -json` incluye los valores sensibles en claro (contraseñas, API keys): por eso el plan se resume a
direcciones y acciones, y hay un test que lo verifica (`test_summary_never_contains_values`).

Cuando el pipeline falla, [`workflow_failure_reason.py`](../scripts/workflow_failure_reason.py) saca la etapa y la
causa del error de la ejecución de Cloud Workflows, para que el registro se baste solo.

## Cómo se consulta

- Panel **"Historial de despliegues"** del dashboard de Cloud Monitoring.
- Logs Explorer: `logName="projects/<proyecto>/logs/paylake-deployments"`, o filtrar `jsonPayload.result="failed"`.
- Alerta **"despliegue fallido"**: la métrica `paylake_dev_deployments_failed` (basada en logs) dispara un correo.
