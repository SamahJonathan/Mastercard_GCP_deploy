# =================================================================================================
#  IAM: TODAS las identidades del proyecto viven en este archivo.  Apuntes: docs/iam.md
#
#  Misma idea que el lab de GCP:
#    - QUIÉN:  una cuenta de servicio por propósito (cada function, cada workflow, Spark, la VM, cada
#              analista, cada emisor). Ninguna usa la cuenta por defecto de Compute Engine.
#    - QUÉ:    roles PROPIOS, acción por acción (custom_roles). Nada de roles/editor, roles/storage.admin
#              ni roles/dataproc.worker (que da lectura y escritura sobre TODOS los objetos del proyecto).
#    - DÓNDE:  cada rol se otorga sobre el recurso más chico posible: un bucket, un prefijo (condición),
#              un managed folder, un dataset, un secreto, un servicio de Cloud Run. Sólo lo que GCP no
#              permite acotar va a nivel de proyecto, y eso queda limitado por el TECHO del bootstrap
#              (infra/bootstrap/grantable_roles.txt): la precondición de abajo lo verifica en el plan.
#    - ADITIVO: siempre *_iam_member (agrega un miembro), nunca *_iam_binding ni *_iam_policy, que
#              reemplazan a todos los miembros, igual que gcloud ... set-iam-policy.
# =================================================================================================

locals {
  # Roles que la cuenta de despliegue puede otorgar a nivel de proyecto (el techo del bootstrap)
  grantable = [
    for l in split("\n", file("${path.module}/../bootstrap/grantable_roles.txt")) :
    replace(trimspace(l), "{project}", var.project_id) if trimspace(l) != "" && !startswith(trimspace(l), "#")
  ]

  # ===============================================================================================
  #  QUIÉN
  # ===============================================================================================
  service_accounts = merge(
    {
      ingest           = "Function ingest: sólo crea lotes en bronze/transactions/"
      bronze-to-silver = "Function bronze->silver: lee Bronze, escribe Silver y registra sus tablas"
      silver-to-gold   = "Function silver->gold: lee Silver, escribe Gold y las liquidaciones salientes"
      api              = "Function de la API: sólo lee Gold"
      dashboard        = "Dashboard Streamlit (Cloud Run): sólo lee la API key"
      fn-build         = "Cloud Build de las functions: lee el código y publica la imagen"
      pipeline-wf      = "Workflow del pipeline: sólo invoca las 3 etapas"
      analytics-wf     = "Workflow diario: sólo lanza el batch de Dataproc con la cuenta dataproc"
      scheduler        = "Cloud Scheduler: sólo inicia ejecuciones de los workflows"
      dataproc         = "Spark (Dataproc Serverless): lee Silver y escribe Gold; nunca Bronze"
      analyst          = "Analista de negocio: BigQuery sobre Gold"
      risk-analyst     = "Analista de riesgo: BigQuery sobre Silver y Gold"
    },
    var.enable_cdc ? { core-loader = "VM de carga del core: su script, el extracto y la clave de la BD" } : {},
    { for i in var.partner_issuers : "partner-${lower(i)}" => "Emisor ${i}: lee sólo sus archivos de liquidación" },
  )

  # ===============================================================================================
  #  QUÉ: roles propios, acción por acción
  # ===============================================================================================
  custom_roles = {
    paylakeObjectCreator = {
      title       = "Crear objetos (sin leer)"
      permissions = ["storage.objects.create"]
    }
    paylakeObjectGetter = {
      title       = "Leer un objeto conocido (sin listar)"
      permissions = ["storage.objects.get"]
    }
    paylakeObjectReplacer = {
      title       = "Crear y reemplazar objetos (sin leer)"
      permissions = ["storage.objects.create", "storage.objects.delete"]
    }
    paylakeObjectReader = {
      title       = "Leer y listar objetos"
      permissions = ["storage.buckets.get", "storage.objects.get", "storage.objects.list"]
    }
    paylakeFolderReader = {
      title       = "Leer y listar objetos de una carpeta administrada"
      permissions = ["storage.objects.get", "storage.objects.list"]
    }
    paylakeObjectWriter = {
      title       = "Leer, listar, crear y borrar objetos"
      permissions = ["storage.buckets.get", "storage.objects.get", "storage.objects.list", "storage.objects.create", "storage.objects.delete"]
    }
    paylakeTableRegistrar = {
      title       = "Registrar tablas BigLake en un dataset"
      permissions = ["bigquery.datasets.get", "bigquery.tables.create", "bigquery.tables.get", "bigquery.tables.update"]
    }
    paylakeConnectionUser = {
      title       = "Crear tablas BigLake con la conexión del lake"
      permissions = ["bigquery.connections.delegate", "bigquery.connections.get", "bigquery.connections.use"]
    }
    paylakeLayerReader = {
      title       = "Consultar las tablas de una capa (se otorga con condición por etiqueta)"
      permissions = ["bigquery.datasets.get", "bigquery.tables.get", "bigquery.tables.list", "bigquery.tables.getData"]
    }
    paylakeBigQueryJobRunner = {
      title       = "Ejecutar consultas y leer resultados (Storage Read API para Power BI)"
      permissions = ["bigquery.jobs.create", "bigquery.readsessions.create", "bigquery.readsessions.getData", "bigquery.readsessions.update"]
    }
    paylakeMetricWriter = {
      title       = "Escribir métricas propias"
      permissions = ["monitoring.timeSeries.create"]
    }
    paylakeLogWriter = {
      title       = "Escribir logs"
      permissions = ["logging.logEntries.create"]
    }
    paylakeSecretReader = {
      title       = "Leer el valor de un secreto"
      permissions = ["secretmanager.versions.access"]
    }
    paylakeFunctionInvoker = {
      title       = "Invocar un servicio de Cloud Run"
      permissions = ["run.routes.invoke"]
    }
    paylakeWorkflowStarter = {
      title       = "Iniciar ejecuciones de workflows"
      permissions = ["workflows.executions.create"]
    }
    paylakeDataprocSubmitter = {
      title       = "Lanzar y seguir batches de Dataproc Serverless"
      permissions = ["dataproc.batches.create", "dataproc.batches.get", "dataproc.operations.get"]
    }
    # roles/dataproc.worker SIN los permisos de Storage (que en el predefinido valen para todo el proyecto)
    paylakeDataprocWorker = {
      title = "Nodo de Dataproc Serverless (sin acceso a Storage)"
      permissions = [
        "dataproc.agents.create", "dataproc.agents.delete", "dataproc.agents.get", "dataproc.agents.list", "dataproc.agents.update",
        "dataproc.tasks.lease", "dataproc.tasks.listInvalidatedLeases", "dataproc.tasks.reportStatus",
        "dataproc.batches.sparkApplicationWrite", "dataproc.batches.computeTuningConfig",
        "dataprocrm.nodePools.create", "dataprocrm.nodePools.delete", "dataprocrm.nodePools.deleteNodes", "dataprocrm.nodePools.get",
        "dataprocrm.nodePools.list", "dataprocrm.nodePools.resize", "dataprocrm.nodes.get", "dataprocrm.nodes.heartbeat",
        "dataprocrm.nodes.list", "dataprocrm.nodes.mintOAuthToken", "dataprocrm.operations.get",
        "logging.logEntries.create", "monitoring.timeSeries.create", "monitoring.metricDescriptors.create",
        "monitoring.metricDescriptors.get", "monitoring.metricDescriptors.list",
        "monitoring.monitoredResourceDescriptors.get", "monitoring.monitoredResourceDescriptors.list",
      ]
    }
  }

  # Nombres armados (no leídos del recurso) para que las claves de for_each se conozcan en el plan
  role       = { for k in keys(local.custom_roles) : k => "projects/${var.project_id}/roles/${k}" }
  sa         = { for k, s in google_service_account.this : k => s.member }
  biglake_sa = "serviceAccount:${google_bigquery_connection.lake.cloud_resource[0].service_account_id}"

  # ===============================================================================================
  #  DÓNDE: buckets (y prefijos)
  # ===============================================================================================
  bucket_grants = concat(
    [
      { id = "ingest", who = local.sa["ingest"], bucket = "bronze", role = "paylakeObjectCreator", prefix = "transactions/" },
      { id = "bronze-to-silver", who = local.sa["bronze-to-silver"], bucket = "bronze", role = "paylakeObjectReader", prefix = "" },
      { id = "bronze-to-silver", who = local.sa["bronze-to-silver"], bucket = "silver", role = "paylakeObjectWriter", prefix = "" },
      { id = "silver-to-gold", who = local.sa["silver-to-gold"], bucket = "silver", role = "paylakeObjectReader", prefix = "" },
      { id = "silver-to-gold", who = local.sa["silver-to-gold"], bucket = "gold", role = "paylakeObjectWriter", prefix = "" },
      { id = "silver-to-gold", who = local.sa["silver-to-gold"], bucket = "exchange", role = "paylakeObjectReplacer", prefix = "outbound/" },
      { id = "api", who = local.sa["api"], bucket = "gold", role = "paylakeObjectReader", prefix = "" },
      { id = "dataproc", who = local.sa["dataproc"], bucket = "silver", role = "paylakeObjectReader", prefix = "" },
      { id = "dataproc", who = local.sa["dataproc"], bucket = "gold", role = "paylakeObjectWriter", prefix = "" },
      # Staging de Dataproc, resultados de calidad y el script: todo en artifacts
      { id = "dataproc", who = local.sa["dataproc"], bucket = "artifacts", role = "paylakeObjectWriter", prefix = "" },
      # La conexión BigLake lee Silver y Gold en nombre de quien consulta (acceso delegado)
      { id = "biglake", who = local.biglake_sa, bucket = "silver", role = "paylakeObjectReader", prefix = "" },
      { id = "biglake", who = local.biglake_sa, bucket = "gold", role = "paylakeObjectReader", prefix = "" },
    ],
    var.enable_cdc ? [
      { id = "core-loader", who = local.sa["core-loader"], bucket = "artifacts", role = "paylakeObjectGetter", prefix = google_storage_bucket_object.core_loader.name },
      { id = "core-loader", who = local.sa["core-loader"], bucket = "bronze", role = "paylakeObjectGetter", prefix = google_storage_bucket_object.core_snapshot.name },
      # Datastream escribe la réplica sólo bajo bronze/datastream/ (list y buckets.get no admiten prefijo)
      { id = "datastream", who = google_project_service_identity.datastream[0].member, bucket = "bronze", role = "paylakeObjectReplacer", prefix = "datastream/" },
      { id = "datastream", who = google_project_service_identity.datastream[0].member, bucket = "bronze", role = "paylakeObjectGetter", prefix = "datastream/" },
      { id = "datastream", who = google_project_service_identity.datastream[0].member, bucket = "bronze", role = "paylakeObjectReader", prefix = "" },
    ] : [],
  )

  # ===============================================================================================
  #  DÓNDE: proyecto (sólo lo que GCP no deja acotar; todo debe estar en el techo del bootstrap)
  # ===============================================================================================
  # Lectura de capas por ETIQUETA del dataset: aplica también a las tablas futuras
  layer_condition = {
    gcf_sources = "resource.name.startsWith('projects/_/buckets/gcf-v2-sources-${local.project_number}-${var.region}')"
    gold        = "resource.matchTag('${var.project_id}/layer', 'gold')"
    silver_gold = "resource.matchTag('${var.project_id}/layer', 'gold') || resource.matchTag('${var.project_id}/layer', 'silver')"
  }
  readers = concat(
    [{ id = "analyst", who = local.sa["analyst"], layers = "gold" }, { id = "risk-analyst", who = local.sa["risk-analyst"], layers = "silver_gold" }],
    [for m in var.analyst_members : { id = m, who = m, layers = "gold" }],
    [for m in var.consultant_members : { id = m, who = m, layers = "gold" }],
    [for m in var.admin_members : { id = m, who = m, layers = "silver_gold" }],
  )

  project_grants = concat(
    [for f in ["ingest", "bronze-to-silver", "silver-to-gold"] : { id = f, who = local.sa[f], role = local.role["paylakeMetricWriter"], condition = "" }],
    [
      { id = "fn-build", who = local.sa["fn-build"], role = local.role["paylakeLogWriter"], condition = "" },
      # Cloud Build publica la imagen en el repositorio gcf-artifacts que crea Cloud Functions (fuera de Terraform)
      { id = "fn-build", who = local.sa["fn-build"], role = "roles/artifactregistry.writer", condition = "" },
      # ...y lee el código desde el bucket gcf-v2-sources-* que también crea Cloud Functions: a nivel de
      # proyecto (el bucket no existe antes del primer despliegue) pero condicionado a ese bucket
      { id = "fn-build", who = local.sa["fn-build"], role = local.role["paylakeFolderReader"], condition = "gcf_sources" },
      { id = "pipeline-wf", who = local.sa["pipeline-wf"], role = local.role["paylakeLogWriter"], condition = "" },
      { id = "analytics-wf", who = local.sa["analytics-wf"], role = local.role["paylakeLogWriter"], condition = "" },
      { id = "analytics-wf", who = local.sa["analytics-wf"], role = local.role["paylakeDataprocSubmitter"], condition = "" },
      { id = "scheduler", who = local.sa["scheduler"], role = local.role["paylakeWorkflowStarter"], condition = "" },
      { id = "dataproc", who = local.sa["dataproc"], role = local.role["paylakeDataprocWorker"], condition = "" },
    ],
    [for r in local.readers : { id = r.id, who = r.who, role = local.role["paylakeBigQueryJobRunner"], condition = "" }],
    [for r in local.readers : { id = r.id, who = r.who, role = local.role["paylakeLayerReader"], condition = r.layers }],
  )

  # Humanos que pueden "ponerse" una identidad (impersonación). Los administradores pueden
  # ponerse todas: check_iam.ps1 prueba DE VERDAD lo permitido y lo denegado actuando como cada cuenta.
  impersonation = merge(
    { for k in keys(local.service_accounts) : k => var.admin_members },
    { for i in var.partner_issuers : "partner-${lower(i)}" => distinct(concat(var.admin_members, var.partner_principals)) },
  )
}

resource "google_service_account" "this" {
  for_each     = local.service_accounts
  account_id   = "${local.name}-${each.key}"
  display_name = "${local.name} ${each.key}"
  description  = each.value
}

resource "google_project_iam_custom_role" "this" {
  for_each    = local.custom_roles
  role_id     = each.key
  title       = each.value.title
  description = "Payments Lakehouse: ${each.value.title}"
  permissions = each.value.permissions
}

resource "google_storage_bucket_iam_member" "grant" {
  for_each = { for g in local.bucket_grants : "${g.bucket}|${g.role}|${g.prefix}|${g.id}" => g }
  bucket   = local.bucket[each.value.bucket]
  role     = local.role[each.value.role]
  member   = each.value.who

  dynamic "condition" {
    for_each = each.value.prefix == "" ? [] : [1]
    content {
      title       = "prefijo ${trimsuffix(each.value.prefix, "/")}"
      description = "Sólo objetos bajo ${each.value.prefix}"
      # Termina en "/" = prefijo; si no, es un objeto exacto
      expression = endswith(each.value.prefix, "/") ? "resource.name.startsWith('${local.objects[each.value.bucket]}${each.value.prefix}')" : "resource.name == '${local.objects[each.value.bucket]}${each.value.prefix}'"
    }
  }

  depends_on = [google_project_iam_custom_role.this]
}

resource "google_project_iam_member" "grant" {
  for_each = { for g in local.project_grants : "${g.role}|${g.condition}|${g.id}" => g }
  project  = var.project_id
  role     = each.value.role
  member   = each.value.who

  dynamic "condition" {
    for_each = each.value.condition == "" ? [] : [1]
    content {
      title      = each.value.condition == "gcf_sources" ? "codigo de Cloud Functions" : "capa ${each.value.condition}"
      expression = local.layer_condition[each.value.condition]
    }
  }

  lifecycle {
    precondition {
      condition     = contains(local.grantable, each.value.role)
      error_message = "El rol ${each.value.role} no está en infra/bootstrap/grantable_roles.txt: agrégalo y vuelve a correr el bootstrap."
    }
  }

  depends_on = [google_project_iam_custom_role.this]
}

# --- Recursos puntuales -------------------------------------------------------------------------

resource "google_bigquery_dataset_iam_member" "registrar" {
  for_each   = { silver = "bronze-to-silver", gold = "silver-to-gold" }
  dataset_id = google_bigquery_dataset.layer[each.key].dataset_id
  role       = local.role["paylakeTableRegistrar"]
  member     = local.sa[each.value]

  depends_on = [google_project_iam_custom_role.this]
}

resource "google_bigquery_connection_iam_member" "delegate" {
  for_each      = toset(["bronze-to-silver", "silver-to-gold"])
  location      = google_bigquery_connection.lake.location
  connection_id = google_bigquery_connection.lake.connection_id
  role          = local.role["paylakeConnectionUser"]
  member        = local.sa[each.key]

  depends_on = [google_project_iam_custom_role.this]
}

resource "google_secret_manager_secret_iam_member" "dashboard_api_key" {
  secret_id  = google_secret_manager_secret.this["api-key"].id
  role       = local.role["paylakeSecretReader"]
  member     = local.sa["dashboard"]
  depends_on = [google_project_iam_custom_role.this]
}

resource "google_secret_manager_secret_iam_member" "reader" {
  for_each = merge(
    { "pan-token-secret" = "bronze-to-silver", "api-key" = "api" },
    var.enable_cdc ? { "core-db-password" = "core-loader" } : {},
  )
  secret_id = google_secret_manager_secret.this[each.key].id
  role      = local.role["paylakeSecretReader"]
  member    = local.sa[each.value]

  depends_on = [google_project_iam_custom_role.this]
}

resource "google_cloud_run_v2_service_iam_member" "invoke_stage" {
  for_each = toset(["ingest", "bronze-to-silver", "silver-to-gold"])
  location = var.region
  name     = google_cloudfunctions2_function.fn[each.key].name
  role     = local.role["paylakeFunctionInvoker"]
  member   = local.sa["pipeline-wf"]

  depends_on = [google_project_iam_custom_role.this]
}

# La API es pública a nivel de red: la protege la x-api-key
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  location = var.region
  name     = google_cloudfunctions2_function.fn["api"].name
  role     = local.role["paylakeFunctionInvoker"]
  member   = "allUsers"

  depends_on = [google_project_iam_custom_role.this]
}

# Para lanzar un batch "como" la cuenta dataproc hace falta actAs sobre ESA cuenta (y ninguna otra)
resource "google_service_account_iam_member" "act_as_dataproc" {
  service_account_id = google_service_account.this["dataproc"].name
  role               = "roles/iam.serviceAccountUser"
  member             = local.sa["analytics-wf"]
}

resource "google_service_account_iam_member" "impersonate" {
  for_each           = { for p in flatten([for sa, members in local.impersonation : [for m in members : { sa = sa, m = m }]]) : "${p.sa}|${p.m}" => p }
  service_account_id = google_service_account.this[each.value.sa].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value.m
}

# Intercambio B2B: cada emisor lista y lee SU carpeta administrada
resource "google_storage_managed_folder_iam_member" "partner" {
  for_each       = toset(var.partner_issuers)
  bucket         = google_storage_managed_folder.partner[each.key].bucket
  managed_folder = google_storage_managed_folder.partner[each.key].name
  role           = local.role["paylakeFolderReader"]
  member         = local.sa["partner-${lower(each.key)}"]
  depends_on     = [google_project_iam_custom_role.this]
}

resource "google_project_service_identity" "datastream" {
  provider = google-beta
  count    = var.enable_cdc ? 1 : 0
  service  = "datastream.googleapis.com"
}
