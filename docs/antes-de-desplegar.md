# Antes de desplegar

## Requisitos

| Herramienta | Versión | Para qué |
|---|---|---|
| Google Cloud SDK (`gcloud`, `bq`) | reciente | bootstrap, comprobaciones, consultas |
| Terraform | ≥ 1.10 | la plataforma |
| Python | 3.12 | tests, scripts |
| PowerShell | 7 | los comandos de `infra/command/` (hay versión bash de `deploy`) |
| `gh` (opcional) | — | que el bootstrap cargue las variables del repositorio |

Una cuenta de Google con una **cuenta de facturación** activa. No hace falta una organización.

## Credenciales

```powershell
gcloud auth login                         # para gcloud / bq
gcloud auth application-default login     # para Terraform (Application Default Credentials)
```

Nada de llaves JSON: Terraform usa tus credenciales de usuario en el PC y Workload Identity Federation en GitHub.

## Primera vez

```powershell
./infra/bootstrap/bootstrap.ps1 -BillingAccount <XXXXXX-XXXXXX-XXXXXX> -AlertEmail tu@correo.com
./infra/command/deploy.ps1 -RunPipeline
```

El bootstrap crea un proyecto nuevo `paylake-gcp-xxxx` (o reutiliza el de `infra/platform/project.auto.tfvars`),
y escribe `backend.hcl` y `project.auto.tfvars`, ambos fuera de git. **No cambia** el proyecto activo de tu
configuración de gcloud: todos los comandos pasan `--project`.

El primer `deploy` tarda ~25 minutos: Cloud SQL (~12), la compilación de las 4 functions y una espera de 5
minutos para que la VM cargue el core antes de iniciar Datastream.

## Costos

| Pieza | Costo aproximado (southamerica-east1) |
|---|---|
| Cloud Run functions, Workflows, Scheduler, GCS, BigQuery, Logging | centavos (la mayoría dentro de la capa gratuita) |
| Dataproc Serverless (diario, 12 vCPU × ~3 min) | ~USD 0,10 por ejecución |
| Cloud KMS (1 llave) + Secret Manager | ~USD 0,10 / mes |
| Cloud SQL `db-f1-micro` + VM `e2-micro` + IP efímera | ~USD 0,70 / día |
| Datastream | por GB procesado: centavos con este volumen |

Una semana con todo encendido ronda **USD 5–8** (estimación). El presupuesto del bootstrap avisa al 80 % real y
al 100 % pronosticado (25 USD convertidos a la moneda de la cuenta de facturación).

Para apagar lo que cuesta por hora sin destruir nada: `./infra/command/destroy.ps1 -StopCdc`.
Para borrar todo, incluido el proyecto: `./infra/command/destroy.ps1` y luego `gcloud projects delete <proyecto>`.

## Problemas que ya aparecieron

Los que surgieron al desplegar por primera vez, con su causa y su corrección (todas ya están en el código):

| # | Síntoma | Causa | Corrección |
|---|---|---|---|
| 1 | El bootstrap fallaba con *"no se encuentra ningún parámetro posicional que acepte 'create'"* | la función se llamaba `Gc`, que en PowerShell es alias de `Get-Content` | renombrada a `Invoke-GCloud` |
| 2 | `services enable` → `SU_MAX_BATCH_SIZE_EXCEEDED` | la API habilita como máximo 20 servicios por llamada | lotes de 20 |
| 3 | `add-iam-policy-binding` → *"Service account … does not exist"* justo después de crearla | consistencia eventual de IAM | reintentos (6 × 10 s) sólo en las asignaciones |
| 4 | `billing budgets create` → `INVALID_ARGUMENT` | la cuenta de facturación es en **CLP**: el monto debe ir en esa moneda | el bootstrap lee `currencyCode` y convierte |
| 5 | quitar la condición vieja del techo → *"valid keys are [None, description, expression, title]"* | la expresión lleva comas; `--condition` no las admite | condición por archivo (`--condition-from-file`) |
| 6 | Las functions quedaban `FAILED`: *"Access to bucket gcf-v2-sources-… denied"* | Cloud Functions copia el código a SU bucket y compila desde ahí con la cuenta `fn-build` | `paylakeFolderReader` condicionado a ese bucket (ver [iam.md](iam.md)) |
| 7 | Las tablas externas no se creaban: *"Cannot query hive partitioned data … without any associated files"* | BigQuery exige archivos al crear una tabla externa particionada | marcadores de 0 filas en una partición de 1900 ([`make_placeholders.py`](../scripts/make_placeholders.py)) |
| 8 | Policy Troubleshooter respondía `CANNOT_ACCESS` a permisos que sí existen | no evalúa condiciones por prefijo de objeto de GCS | `check_iam.ps1` hace pruebas reales con impersonación |
| 9 | Un Owner no podía impersonar las cuentas del proyecto | `roles/owner` no incluye `iam.serviceAccounts.getAccessToken` | `serviceAccountTokenCreator` explícito para `admin_members` |
| 10 | (diseño) `roles/dataproc.worker` daba a Spark lectura, escritura y `setIamPolicy` sobre **todos** los objetos | el rol predefinido incluye `storage.objects.*` a nivel de proyecto | rol propio `paylakeDataprocWorker` sin `storage.*` + permisos por bucket |
| 11 | 3 de las 4 functions: `409 Could not create bucket gcf-v2-sources-…` | las 4 se crean en paralelo y cada una intenta crear el bucket de código de Cloud Functions | transitorio: el siguiente `apply` las crea (el bucket ya existe) |
| 12 | `Workflows service agent does not exist` | el agente de servicio se crea con el primer uso de la API | `google_project_service_identity.workflows` |
| 13 | alertas sobre métricas de logs → *"must specify a restriction on resource.type"* | Monitoring exige acotar el tipo de recurso | `resource.type=one_of(...)` (audit logs) y `resource.type="global"` (despliegues) |
| 14 | `symbol 'googleapis.dataproc.v1…' not found` | Cloud Workflows no tiene conector de Dataproc | llamada REST con OAuth2 + consulta del batch cada 30 s |
| 15 | `Unterminated expression` en el YAML del workflow | la expresión del `raise` contenía `": "`, que YAML lee como clave | expresión entre comillas simples |
| 16 | **¡el plan quitaba las etiquetas de los datasets!** (el analista perdía el acceso a Gold) | BigQuery reporta los tag bindings como `resource_tags` del dataset y Terraform los veía como sobrantes | etiquetas en `resource_tags` del propio dataset + bloque `removed` para soltar los bindings sin borrarlos |
| 17 | cada plan reemplazaba el perfil y el stream de Datastream (re-backfill completo) | la API no devuelve el `ca_certificate` ni la contraseña | `ignore_changes` sólo sobre esos dos atributos |
| 18 | cada plan reemplazaba las tablas externas y actualizaba el dashboard | BigQuery agrega la columna de partición al esquema; Monitoring normaliza el JSON | `ignore_changes` + `replace_triggered_by` con el hash de lo declarado |
