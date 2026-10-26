# Un bucket por capa: permite IAM, retención y cifrado independientes por nivel de madurez del dato.
# Todos con acceso uniforme (sólo IAM, sin ACLs por objeto) y bloqueo de acceso público.
resource "google_storage_bucket" "layer" {
  for_each = toset(local.layers)
  name     = "${var.project_id}-${each.key}"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.environment != "prod"

  # CMEK en todo menos auditoría: el sink de logs escribe con una identidad de Google que no usa la llave
  dynamic "encryption" {
    for_each = each.key == "audit" ? [] : [1]
    content {
      default_kms_key_name = google_kms_crypto_key.lake.id
    }
  }

  # Bronze (fuente de verdad, inmutable) y Exchange (archivos entregados a terceros) quedan versionados
  versioning {
    enabled = contains(["bronze", "exchange"], each.key)
  }

  dynamic "lifecycle_rule" {
    for_each = each.key == "bronze" ? [1] : []
    content {
      condition { age = 90 }
      action {
        type          = "SetStorageClass"
        storage_class = "COLDLINE"
      }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = contains(["bronze", "exchange"], each.key) ? [1] : []
    content {
      condition { days_since_noncurrent_time = 30 }
      action { type = "Delete" }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = each.key == "audit" ? [1] : []
    content {
      condition { age = 90 }
      action { type = "Delete" }
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.service_agents]
}

locals {
  bucket = { for k, b in google_storage_bucket.layer : k => b.name }
  uri    = { for k, b in google_storage_bucket.layer : k => "gs://${b.name}" }
  # Prefijo de objetos de un bucket, para condiciones de IAM: resource.name.startsWith(...)
  objects = { for k, b in google_storage_bucket.layer : k => "projects/_/buckets/${b.name}/objects/" }
}

# --- Intercambio B2B: una carpeta administrada por emisor ---------------------------------------
# Un managed folder lleva su propia política de IAM: el emisor lista y lee sólo lo que está debajo.
resource "google_storage_managed_folder" "partner" {
  for_each      = toset(var.partner_issuers)
  bucket        = google_storage_bucket.layer["exchange"].name
  name          = "outbound/issuer_id=${each.key}/"
  force_destroy = true
}

# --- Objetos que publica el despliegue -------------------------------------------------------

# Extracto del sistema core (sample_data) aterrizado tal cual en Bronze: segunda fuente de ingesta
resource "google_storage_bucket_object" "core_snapshot" {
  bucket       = google_storage_bucket.layer["bronze"].name
  name         = "core_snapshot/ingest_date=${var.core_snapshot_ingest_date}/mastercard_db_ficticia.json"
  source       = "${path.module}/../../sample_data/mastercard_db_ficticia.json"
  content_type = "application/json"
}

resource "google_storage_bucket_object" "dataproc_job" {
  bucket = google_storage_bucket.layer["artifacts"].name
  name   = "dataproc/gold_card_analytics.py"
  source = "${path.module}/../../dataproc/jobs/gold_card_analytics.py"
}

resource "google_storage_bucket_object" "core_loader" {
  bucket = google_storage_bucket.layer["artifacts"].name
  name   = "core_db/load_core_db.py"
  source = "${path.module}/../../scripts/core_db/load_core_db.py"
}
