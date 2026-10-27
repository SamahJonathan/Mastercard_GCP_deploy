# IAM — quién accede y qué puede hacer

Todo vive en un solo archivo: [`infra/platform/iam.tf`](../infra/platform/iam.tf).
El techo de la cuenta de despliegue está en [`infra/bootstrap/grantable_roles.txt`](../infra/bootstrap/grantable_roles.txt)
y lo aplica [`infra/bootstrap/bootstrap.ps1`](../infra/bootstrap/bootstrap.ps1).
Las comprobaciones, en [`infra/command/check_iam.ps1`](../infra/command/check_iam.ps1).

## Las dos preguntas

IAM responde siempre lo mismo: **quién** accede y **qué** puede hacer.

- El **quién** es una **cuenta de servicio**: una identidad para procesos, no para personas. Cada pieza tiene
  la suya: cada Cloud Run function, cada workflow, Spark, la VM de carga, cada tipo de analista, cada banco.
  **Ninguna** usa la cuenta por defecto de Compute Engine (que en proyectos sin organización nace con `roles/editor`).
- El **qué** es un **rol**: un manojo de permisos. Aquí casi todos son **roles propios**, acción por acción.
- El **dónde**: el binding se pone **sobre un recurso** (un bucket, un
  dataset, un secreto, un servicio de Cloud Run) y hereda hacia abajo. Se elige siempre el recurso más chico.

En `iam.tf`:

```hcl
service_accounts = { api = "Function de la API: sólo lee Gold", ... }                       # QUIÉN
custom_roles     = { paylakeObjectReader = ["storage.buckets.get", "storage.objects.get", "storage.objects.list"], ... }  # QUÉ
bucket_grants    = [{ id = "api", bucket = "gold", role = "paylakeObjectReader", prefix = "" }, ...]  # DÓNDE
```

## Conceptos de IAM en GCP, como se usan aquí

| Concepto | En este proyecto |
|---|---|
| cuenta de servicio | una por propósito (`paylake-dev-api`, `paylake-dev-ingest`, …), como `deployer-sa` del lab |
| rol propio | acción por acción (`google_project_iam_custom_role`), como `vm_start_stop` del lab |
| binding sobre un recurso | el rol se otorga sobre el bucket, dataset, secreto o servicio concreto, no sobre el proyecto |
| condición de IAM | acota un binding: `resource.name.startsWith('…/objects/transactions/')` (un prefijo) o `resource.matchTag(...)` (una etiqueta) |
| impersonación | `roles/iam.serviceAccountTokenCreator` sobre una cuenta: quién puede actuar como ella |
| techo de roles | `projectIamAdmin` condicionado con `modifiedGrantsByRole.hasOnly([...])` |
| BigLake + etiquetas | la conexión lee GCS; las etiquetas `layer`/`sensitivity` de cada dataset deciden quién lee qué capa |
| `*_iam_member` (añade) | el único tipo de binding que se usa |
| `*_iam_binding` / `*_iam_policy` (reemplazan a todos los miembros, como `set-iam-policy`) | **no se usan** |
| Workload Identity Federation | GitHub canjea su token OIDC por credenciales de corta duración; el provider acepta sólo `assertion.repository == 'SamahJonathan/Mastercard_GCP_deploy'` |

## Las identidades y sus llaves

| Identidad | Para qué | Llaves (rol propio → sobre qué) |
|---|---|---|
| `ingest` | aterriza lotes en Bronze | `paylakeObjectCreator` → bronze, **sólo** `transactions/`; `paylakeMetricWriter` → proyecto |
| `bronze-to-silver` | Bronze → Silver | `paylakeObjectReader` → bronze; `paylakeObjectWriter` → silver; `paylakeTableRegistrar` → dataset silver; `paylakeConnectionUser` → conexión BigLake; `paylakeSecretReader` → secreto del token de PAN; métricas |
| `silver-to-gold` | Silver → Gold + liquidaciones | `paylakeObjectReader` → silver; `paylakeObjectWriter` → gold; `paylakeObjectReplacer` → exchange, **sólo** `outbound/`; registrar tablas en gold y sus vistas en reports; conexión; métricas |
| `api` | sirve Gold por HTTP | `paylakeObjectReader` → gold; `paylakeSecretReader` → secreto de la API key |
| `dashboard` | Streamlit en Cloud Run | `paylakeSecretReader` → secreto de la API key |
| `fn-build` | compila las functions | `paylakeLogWriter` → proyecto; `roles/artifactregistry.writer` → proyecto; `paylakeFolderReader` → proyecto **condicionado** al bucket `gcf-v2-sources-*` |
| `pipeline-wf` | workflow del pipeline | `paylakeFunctionInvoker` → **cada uno** de los 3 servicios de Cloud Run; logs |
| `analytics-wf` | workflow diario de Spark | `paylakeDataprocSubmitter` → proyecto; `roles/iam.serviceAccountUser` → **sólo** la cuenta `dataproc`; logs |
| `scheduler` | Cloud Scheduler | `paylakeWorkflowStarter` → proyecto (una sola acción: `workflows.executions.create`) |
| `dataproc` | Spark | `paylakeDataprocWorker` → proyecto; `paylakeObjectReader` → silver; `paylakeObjectWriter` → gold y artifacts |
| `core-loader` | VM que carga el core | `paylakeObjectGetter` → **dos objetos exactos** (su script y el extracto); `paylakeSecretReader` → clave de la BD |
| `analyst` | analista de negocio | `paylakeBigQueryJobRunner` → proyecto; `paylakeLayerReader` → proyecto **condicionado** a `layer = gold` |
| `risk-analyst` | analista de riesgo | igual, condicionado a `layer = gold` **o** `layer = silver` |
| `partner-em001`, `partner-em005` | cada banco emisor | `paylakeFolderReader` → **su** carpeta administrada `outbound/issuer_id=EMxxx/` |
| conexión BigLake (de Google) | lee Silver/Gold para quien consulta | `paylakeObjectReader` → silver y gold |
| agente de Datastream (de Google) | escribe la réplica CDC | `paylakeObjectReplacer` + `paylakeObjectGetter` → bronze **sólo** `datastream/`; `paylakeObjectReader` → bronze (list no admite prefijo) |

Personas (variables de Terraform, sin cuentas propias que administrar):

| Lista | Acceso |
|---|---|
| `admin_members` | lo mismo que `risk-analyst` (Silver + Gold) y pueden impersonar las identidades del proyecto para probarlas |
| `analyst_members` | lo mismo que `analyst` (sólo Gold) |
| `consultant_members` | consultan Gold directo con su cuenta de Google, sin cambiar de identidad |

El **dashboard web** (Streamlit en Cloud Run) está detrás de **Identity-Aware Proxy**: cada persona inicia sesión con
su cuenta de Google y sólo pasan las de estas tres listas (`roles/iap.httpsResourceAccessor`, un solo permiso). El
servicio no es público: su único invocador es el agente de IAP. La API key de Gold la lee la cuenta `dashboard`
desde Secret Manager y nunca llega al navegador.

En un proyecto **sin organización**, IAP necesita un cliente OAuth propio, que sólo se crea desde la consola:
*Google Auth Platform* → *Público*: **Externo**, en **Prueba**, con las cuentas autorizadas como usuarios de prueba →
*Clientes* → *Aplicación web* con el URI de redirección `https://iap.googleapis.com/v1/oauth/clientIds/<CLIENT_ID>:handleRedirect`.
El ID y el secreto van en `iap_oauth_client_id` / `iap_oauth_client_secret` de `project.auto.tfvars` (fuera de git).

## Gobierno por etiquetas

1. Cada dataset lleva dos etiquetas de Resource Manager:

   | Dataset | `layer` | `sensitivity` |
   |---|---|---|
   | `paylake_dev_bronze` | `bronze` | `restricted` (PAN en claro) |
   | `paylake_dev_silver` | `silver` | `confidential` (tokens, detalle transaccional) |
   | `paylake_dev_gold` | `gold` | `public` (agregados) |

2. Los lectores reciben `paylakeLayerReader` **a nivel de proyecto**, pero con la condición
   `resource.matchTag('paylake-gcp-xxxx/layer', 'gold')`. Las tablas heredan las etiquetas del dataset, así que
   una tabla nueva de Gold queda disponible sola, sin tocar IAM.
3. Las tablas de Silver y Gold son **BigLake**: BigQuery lee los Parquet de GCS con la cuenta de la conexión. El
   analista **no** tiene permisos sobre los buckets: si intenta leer el archivo directo, Cloud Storage lo rechaza.
4. Bronze es una tabla externa **común** (sin conexión): para consultarla hay que poder leer el bucket, y ningún
   analista puede. Bronze queda protegida sólo por IAM.

## El techo de la cuenta de despliegue

`paylake-deploy` (la que usa GitHub Actions) tiene roles de administración por servicio
(`storage.admin`, `bigquery.admin`, `run.admin`, …) para crear y borrar recursos, pero **ningún** rol que permita
otorgar permisos a nivel de proyecto salvo uno:

```
roles/resourcemanager.projectIamAdmin  con la condición
api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([
  'projects/paylake-gcp-xxxx/roles/paylakeMetricWriter', ..., 'roles/artifactregistry.writer'])
```

Puede agregar o quitar **sólo** los roles de [`grantable_roles.txt`](../infra/bootstrap/grantable_roles.txt).
Si Terraform (o alguien que robe el token de GitHub) intenta otorgar `roles/owner` o `roles/editor`, IAM lo
rechaza. Cada `google_project_iam_member` de `iam.tf` tiene una `precondition` que verifica, ya en el `plan`,
que su rol está en esa lista.

## Permisos que NO damos

| Lo que no damos | Lo que se usa en su lugar | Por qué |
|---|---|---|
| `roles/editor`, `roles/owner` a cualquier cuenta de servicio | roles propios por recurso | un editor puede leer todos los buckets, incluido Bronze |
| `roles/storage.admin` / `objectAdmin` a las functions | `paylakeObjectCreator/Reader/Writer/Replacer` por bucket y prefijo | `ingest` crea pero **no lee**: no puede extraer los PAN que aterriza |
| `roles/dataproc.worker` a Spark | `paylakeDataprocWorker` (el mismo rol **sin** `storage.*`) | el predefinido da leer, escribir y **cambiar el IAM** de todos los objetos del proyecto |
| `roles/run.invoker` | `paylakeFunctionInvoker` (sólo `run.routes.invoke`) por servicio | el workflow invoca sus 3 etapas y nada más |
| `roles/workflows.invoker` | `paylakeWorkflowStarter` (sólo `executions.create`) | Scheduler no puede leer resultados ni cancelar ejecuciones |
| `roles/bigquery.dataViewer` a nivel de proyecto | `paylakeLayerReader` condicionado por etiqueta | el analista ve Gold, no Silver ni Bronze |
| `roles/secretmanager.secretAccessor` a nivel de proyecto | `paylakeSecretReader` sobre **cada** secreto | la API lee su key, no el secreto de tokenización |
| `roles/iam.serviceAccountUser` a nivel de proyecto | sobre **una** cuenta (`dataproc`) | el workflow de Spark no puede lanzar cosas como otra identidad |
| llaves JSON de cuentas de servicio | WIF (GitHub) e impersonación (personas) | nada de credenciales de larga duración |
| SSH abierto a internet en la VM | IAP (`35.235.240.0/20`) + OS Login | no hay puertos de entrada |
| `*_iam_binding` / `*_iam_policy` en Terraform | `*_iam_member` | los primeros borran a los miembros que no declaran (como `set-iam-policy`) |

### Lo que sí damos a propósito (y por qué)

- **`roles/artifactregistry.writer` a nivel de proyecto** para `fn-build`: Cloud Functions crea el repositorio
  `gcf-artifacts` por su cuenta, fuera de Terraform; no hay un recurso sobre el cual acotarlo.
- **`paylakeFolderReader` a nivel de proyecto, condicionado al bucket `gcf-v2-sources-<n>-<región>`**: Cloud
  Functions copia ahí el código antes de compilar y ese bucket no existe hasta el primer despliegue.
- **Los administradores pueden impersonar las identidades del proyecto**: `check_iam.ps1` prueba de verdad lo
  denegado actuando como cada una. Un Owner podría otorgárselo igual; así queda explícito y en código.

## Comprobaciones

`./infra/command/check_iam.ps1` (también lo corre `deploy.ps1` al final) actúa como cada identidad e intenta
operaciones reales: 33 casos, la mayoría para verificar lo que **debe quedar denegado**.

¿Por qué no un simulador? Policy Troubleshooter (el simulador de IAM de Google) no evalúa las
condiciones por prefijo de objeto de Cloud Storage: evalúa `resource.name` contra el bucket y responde
`CANNOT_ACCESS` aunque el permiso exista. Una prueba real no tiene ese punto ciego. Las escrituras que se prueban
son sólo las que deben fallar, así que no ensucian los datos; que las permitidas funcionan lo demuestra el pipeline.

| Identidad | Prueba | Esperado |
|---|---|---|
| ingest | leer Bronze · escribir Silver · escribir fuera de `transactions/` | denegado |
| bronze-to-silver | leer Bronze / escribir Gold | permitido / denegado |
| silver-to-gold | leer Bronze · escribir Exchange fuera de `outbound/` | denegado |
| api | listar Gold / listar Silver · escribir Gold | permitido / denegado |
| dataproc | leer Bronze · **cambiar el IAM de Bronze** | denegado (con `roles/dataproc.worker` sería permitido) |
| analyst | BigQuery Gold / Silver · Bronze · leer el Parquet directo · darse Owner | permitido / denegado |
| risk-analyst | BigQuery Silver / Bronze · leer el Parquet directo | permitido / denegado |
| partner-em001 | leer y listar **su** carpeta / leer la de EM005 · listar todo Exchange | permitido / denegado |
| scheduler | invocar una function | denegado |
| core-loader | leer el extracto / listar Bronze | permitido / denegado |
| paylake-deploy | darse Owner · dar Editor a otra cuenta · crear una llave JSON | denegado |
