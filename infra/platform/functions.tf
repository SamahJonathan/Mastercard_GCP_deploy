# Cloud Run functions (2.ª gen., Python 3.12): las 3 etapas del pipeline y la API de Gold.
# Las cuatro comparten el mismo código (src/: main.py + payments_lake/ + requirements.txt); cambia el entry_point.

data "archive_file" "src" {
  type        = "zip"
  source_dir  = "${path.module}/../../src"
  output_path = "${path.module}/.build/payments_lake.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
  # Permisos fijos: sin esto el zip (y su hash) cambia entre Windows y Linux, y cada despliegue alternado
  # entre el PC y GitHub Actions volvería a compilar las 4 functions
  output_file_mode = "0644"
}

# El nombre lleva el hash: un cambio de código sube un objeto nuevo y Cloud Functions vuelve a construir
resource "google_storage_bucket_object" "functions_source" {
  bucket = google_storage_bucket.layer["artifacts"].name
  name   = "functions/payments_lake-${data.archive_file.src.output_md5}.zip"
  source = data.archive_file.src.output_path
}

locals {
  common_env = {
    GCP_PROJECT       = var.project_id
    ENVIRONMENT       = var.environment
    BRONZE_ROOT       = local.uri["bronze"]
    SILVER_ROOT       = local.uri["silver"]
    GOLD_ROOT         = local.uri["gold"]
    EXCHANGE_ROOT     = local.uri["exchange"]
    BQ_DATASET_SILVER = google_bigquery_dataset.layer["silver"].dataset_id
    BQ_DATASET_GOLD   = google_bigquery_dataset.layer["gold"].dataset_id
    BQ_CONNECTION     = "${var.project_id}.${var.region}.${google_bigquery_connection.lake.connection_id}"
    LOOKBACK_DAYS     = tostring(var.lookback_days)
  }

  functions = {
    ingest = {
      entry_point = "ingest"
      memory      = "512Mi"
      timeout     = 120
      env         = { BATCH_SIZE = tostring(var.batch_size) }
    }
    bronze-to-silver = {
      entry_point = "bronze_to_silver"
      memory      = "2Gi"
      timeout     = 540
      env         = { PAN_TOKEN_SECRET_NAME = google_secret_manager_secret.this["pan-token-secret"].id }
    }
    silver-to-gold = {
      entry_point = "silver_to_gold"
      memory      = "2Gi"
      timeout     = 540
      env         = {}
    }
    api = {
      entry_point = "gold_api"
      memory      = "1Gi"
      timeout     = 60
      env         = { API_KEY_SECRET_NAME = google_secret_manager_secret.this["api-key"].id }
    }
  }
}

resource "google_cloudfunctions2_function" "fn" {
  for_each    = local.functions
  name        = "${local.name}-${each.key}"
  location    = var.region
  description = "Payments Lakehouse: ${each.key}"

  build_config {
    runtime         = "python312"
    entry_point     = each.value.entry_point
    service_account = google_service_account.this["fn-build"].id
    source {
      storage_source {
        bucket = google_storage_bucket.layer["artifacts"].name
        object = google_storage_bucket_object.functions_source.name
      }
    }
  }

  service_config {
    available_memory      = each.value.memory
    available_cpu         = each.value.memory == "2Gi" ? "1" : null
    timeout_seconds       = each.value.timeout
    max_instance_count    = each.key == "api" ? 5 : 1 # el pipeline corre de a una ejecución
    min_instance_count    = 0
    service_account_email = google_service_account.this[each.key].email
    ingress_settings      = "ALLOW_ALL"
    environment_variables = merge(local.common_env, each.value.env)
  }

  depends_on = [
    google_project_iam_member.grant,
    google_storage_bucket_iam_member.grant,
    google_secret_manager_secret_iam_member.reader,
  ]
}
