# Comandos

Todo lo que se ejecuta a mano vive aquí. Requisitos y primera vez: [docs/antes-de-desplegar.md](../../docs/antes-de-desplegar.md).

| Comando | Cuándo | Qué hace |
|---|---|---|
| `../bootstrap/bootstrap.ps1 -BillingAccount … -AlertEmail …` | una vez (y al cambiar el techo de roles) | proyecto, APIs, estado de Terraform, cuenta de despliegue con techo, OIDC de GitHub, historial de despliegues, presupuesto |
| `deploy.ps1` | cada cambio | tests → `fmt` → `init`/`validate` → `plan` → `apply` (pide confirmación) → `check_iam.ps1` |
| `deploy.ps1 -PlanOnly` | antes de un cambio delicado | sólo el plan |
| `deploy.ps1 -RunPipeline` | para verlo funcionar | además ejecuta el workflow del pipeline y espera el resultado |
| `deploy.sh [--auto] [--pipeline]` | Cloud Shell / Linux | lo mismo en bash |
| `check_iam.ps1` | después de tocar IAM | 33 pruebas reales: lo permitido y lo que debe quedar denegado |
| `destroy.ps1 -PauseOnly` | al dejar de mostrarlo | pausa los jobs de Cloud Scheduler |
| `destroy.ps1 -StopCdc` | para no pagar por hora | además apaga Cloud SQL, la VM y Datastream |
| `destroy.ps1` | al terminar | destruye la plataforma (el bootstrap se conserva) |
| `python scripts/run_queries.py` | consultar | las 12 consultas de `sql/` en BigQuery, con tope de 1 GB por consulta |
| `bash dashboard/deploy_cloudrun.sh <proyecto>` | opcional | el dashboard de Streamlit en Cloud Run |

Cada `deploy`/`destroy` queda registrado en Cloud Logging y en el bucket del estado:
[docs/observabilidad-despliegues.md](../../docs/observabilidad-despliegues.md).
