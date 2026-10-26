data "google_project" "this" {}

locals {
  name           = "${var.project}-${var.environment}"
  project_number = data.google_project.this.number
  ds_prefix      = replace(local.name, "-", "_")

  layers = ["bronze", "silver", "gold", "exchange", "artifacts", "audit"]
}

resource "random_id" "suffix" {
  byte_length = 2
}

# --- Cifrado ---------------------------------------------------------------------------------
# Una llave (CMEK) para todo el lake: buckets, secretos y la conexión de BigQuery.
# Las llaves de Cloud KMS no se pueden borrar (sólo sus versiones): el sufijo permite volver a desplegar
# después de un destroy sin chocar con el llavero anterior.
resource "google_kms_key_ring" "lake" {
  name     = "${local.name}-lake-${random_id.suffix.hex}"
  location = var.region
}

resource "google_kms_crypto_key" "lake" {
  name            = "lake"
  key_ring        = google_kms_key_ring.lake.id
  rotation_period = "7776000s" # 90 días
}

# Agentes de servicio de Google que cifran/descifran con la llave en nombre de cada servicio
data "google_storage_project_service_account" "gcs" {}

resource "google_project_service_identity" "secretmanager" {
  provider = google-beta
  service  = "secretmanager.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "service_agents" {
  for_each = {
    storage       = data.google_storage_project_service_account.gcs.member
    secretmanager = google_project_service_identity.secretmanager.member
  }
  crypto_key_id = google_kms_crypto_key.lake.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value
}

# --- Secretos (Secret Manager, cifrados con la llave del lake) --------------------------------
resource "random_password" "pan_token_secret" {
  length  = 48
  special = false
}

resource "random_password" "api_key" {
  length  = 40
  special = false
}

# Contraseña del dashboard web (para quien no tiene cuenta de Google y no puede entrar a BigQuery)
resource "random_password" "dashboard" {
  length  = 16
  special = false
}

locals {
  secrets = merge(
    {
      pan-token-secret   = random_password.pan_token_secret.result
      api-key            = random_password.api_key.result
      dashboard-password = random_password.dashboard.result
    },
    var.enable_cdc ? { core-db-password = random_password.core_db[0].result } : {},
  )
}

resource "google_secret_manager_secret" "this" {
  for_each  = nonsensitive(toset(keys(local.secrets)))
  secret_id = "${local.name}-${each.key}"

  replication {
    user_managed {
      replicas {
        location = var.region
        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.lake.id
        }
      }
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.service_agents]
}

resource "google_secret_manager_secret_version" "this" {
  for_each    = google_secret_manager_secret.this
  secret      = each.value.id
  secret_data = local.secrets[each.key]
}
